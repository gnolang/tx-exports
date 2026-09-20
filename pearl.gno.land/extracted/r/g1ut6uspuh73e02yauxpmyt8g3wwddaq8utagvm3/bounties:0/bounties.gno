// Realm bounties is a GNOT bounty board that COMPOSES the reusable
// accounting package gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger
// instead of re-implementing balance accounting.
//
// STATE OWNERSHIP (the dependency boundary):
//   - This realm owns the bounty state machine: bounty records (funder,
//     title, amount, status, winner), the sum of open escrow
//     (openTotal), and per-bounty funder authorization.
//   - feeledger owns all claimable-balance accounting: per-account
//     balances, the protocol-fee pot, fee rounding, overflow checks,
//     and withdraw arithmetic. This realm never duplicates that logic;
//     it only calls the ledger API and panics on its errors.
//
// LIFECYCLE:
//
//	CreateBounty (EOA + -send)  : escrow -> openTotal, status Open
//	Award (funder only)         : openTotal -> ledger.Deposit(winner,
//	                              amount, snapshot fee)
//	Cancel (funder only)        : openTotal -> ledger.Deposit(funder,
//	                              amount, 0)       [no fee on refund]
//	Claim / ClaimAll (anyone)   : pays out the caller's ledger balance
//	WithdrawFees (fee recipient): pays out the fee pot
//
// Awarded and Cancelled are terminal; a bounty transitions exactly once.
//
// FEE MODEL: fee = floor(amount * bps / 10000), rounding favors the
// recipient, no minimum fee, admin-settable up to the compile-time
// MaxFeeBps cap, accrued to a pot withdrawable by the fee recipient
// role. The applicable bps is SNAPSHOTTED INTO THE BOUNTY AT CREATION
// and charged at Award: the funder commits to the fee they saw, and a
// later SetFeeBps affects only bounties created afterwards (this
// closes the admin front-run found in the composition audit). Refunds
// via Cancel are always fee-free. A failed Award (e.g. ledger
// overflow) leaves the bounty Open — the funder can retry or Cancel.
//
// COMPOSED ACCOUNTING INVARIANT: let H be ugnot held at this realm's
// address, B = openTotal (application escrow), U+F the ledger's
// liabilities, S >= 0 out-of-band surplus. At every transaction
// boundary:
//
//	H == B + U + F + S
//
// Derivation: CreateBounty raises H and B equally (the IsUserCall +
// envelope guard is the receipt-guaranteed shape, validated live on
// pearl-1); Award/Cancel move amount from B into U+F within one
// transaction, and feeledger guarantees credited + fee == amount;
// Claim/WithdrawFees debit the ledger before sending the identical
// amount (checks-effects-interactions), lowering H and U+F equally;
// any panic aborts the whole transaction; this realm never issues or
// removes coins. The application invariant B == Σ amount(Open) is
// maintained in lockstep with every status transition.
//
// ONLY GNOT: CreateBounty rejects any envelope that is not exactly one
// positive ugnot coin. Foreign denominations force-sent to the realm
// sit in surplus and are recoverable via SweepDenom (fee recipient
// only), which never touches B, U, or F.
package bounties

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/nt/avl/v0"
)

// Denom is the only asset this realm accepts.
const Denom = "ugnot"

// MaxFeeBps is the hard protocol-fee cap: 1000 bps = 10%.
const MaxFeeBps = int64(1000)

// Bounty status values.
const (
	StatusOpen      = "open"
	StatusAwarded   = "awarded"
	StatusCancelled = "cancelled"
)

const maxTitleLen = 80

// Bounty is one bounty record. Fields are unexported; read access goes
// through BountyInfo so no interior pointers escape the realm.
type bounty struct {
	id     int64
	funder address
	title  string
	amount int64
	feeBps int64 // fee policy snapshotted at creation, charged at Award
	status string
	winner address // set iff status == StatusAwarded
}

var (
	admin        address // may set fee, fee recipient, successor admin
	feeRecipient address // may withdraw fees and sweep surplus
	feeBps       int64   // protocol fee snapshotted into new bounties

	self      address // this realm's address, captured at deploy
	nextID    int64   // next bounty id (first bounty gets id 1)
	openTotal int64   // == Σ amount over bounties with status Open

	bounties = avl.NewTree() // padID(id) -> *bounty
	ledger   = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// CreateBounty escrows the attached GNOT as a new open bounty and
// returns its id. Only direct EOA calls with -send are accepted (the
// receipt-guaranteed shape). The envelope must be exactly one positive
// ugnot coin. The caller becomes the bounty's funder.
func CreateBounty(cur realm, title string) int64 {
	if !cur.Previous().IsUserCall() {
		panic("bounty creation must be a direct EOA call with -send")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic("send exactly one coin type: " + Denom)
	}
	amount := sent[0].Amount
	if amount <= 0 {
		panic("bounty amount must be positive")
	}
	assertValidTitle(title)

	newOpenTotal, ok := checkedAdd(openTotal, amount)
	if !ok {
		panic("open escrow overflow")
	}

	funder := cur.Previous().Address()
	nextID++
	b := &bounty{
		id:     nextID,
		funder: funder,
		title:  title,
		amount: amount,
		feeBps: feeBps, // snapshot: later SetFeeBps cannot change this bounty's fee
		status: StatusOpen,
	}
	bounties.Set(padID(b.id), b)
	openTotal = newOpenTotal

	chain.Emit("BountyCreated",
		"id", itoa(b.id),
		"funder", funder.String(),
		"amount", itoa(amount),
		"feeBps", itoa(b.feeBps),
	)
	return b.id
}

// Award closes an open bounty in favor of winner: the escrowed amount
// leaves the open pool and is credited to winner's claimable balance
// through the ledger, charging the fee snapshotted at creation. Only
// the bounty's funder may award it. Terminal: an awarded bounty can
// never change again.
func Award(cur realm, id int64, winner address) {
	caller := cur.Previous().Address()
	b := mustGetBounty(id)
	if caller != b.funder {
		panic("only the bounty funder may award")
	}
	if b.status != StatusOpen {
		panic("bounty is not open")
	}
	var zero address
	if winner == zero {
		panic("empty winner address")
	}

	// Move the escrow from application state into ledger liabilities in
	// one transaction, at the fee snapshotted when the bounty was
	// created. feeledger validates before mutating and guarantees
	// credited + fee == amount; an error aborts everything and leaves
	// the bounty Open.
	credited, fee, err := ledger.Deposit(winner.String(), b.amount, b.feeBps)
	if err != nil {
		panic(err)
	}
	openTotal -= b.amount // >= 0: openTotal == Σ open amounts >= b.amount
	b.status = StatusAwarded
	b.winner = winner

	chain.Emit("BountyAwarded",
		"id", itoa(id),
		"winner", winner.String(),
		"credited", itoa(credited),
		"fee", itoa(fee),
	)
}

// Cancel closes an open bounty and refunds its escrow to the funder's
// claimable balance, fee-free. Only the bounty's funder may cancel.
// Terminal: a cancelled bounty can never change again.
func Cancel(cur realm, id int64) {
	caller := cur.Previous().Address()
	b := mustGetBounty(id)
	if caller != b.funder {
		panic("only the bounty funder may cancel")
	}
	if b.status != StatusOpen {
		panic("bounty is not open")
	}

	if _, _, err := ledger.Deposit(b.funder.String(), b.amount, 0); err != nil {
		panic(err)
	}
	openTotal -= b.amount
	b.status = StatusCancelled

	chain.Emit("BountyCancelled", "id", itoa(id), "funder", b.funder.String())
}

// Claim sends amount ugnot of the caller's claimable balance (won
// bounties and refunds) back to the caller.
func Claim(cur realm, amount int64) {
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	send(cur, caller, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire claimable balance back to the
// caller. Fails if there is nothing to claim.
func ClaimAll(cur realm) {
	caller := cur.Previous().Address()
	amount, err := ledger.WithdrawAll(caller.String())
	if err != nil {
		panic(err)
	}
	if amount == 0 {
		panic("nothing to claim")
	}
	send(cur, caller, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// WithdrawFees sends the accrued fee pot to the fee recipient. Only the
// fee recipient may call it.
func WithdrawFees(cur realm) {
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may withdraw fees")
	}
	amount := ledger.WithdrawFees()
	if amount == 0 {
		panic("no fees accrued")
	}
	send(cur, feeRecipient, amount)
	chain.Emit("FeesWithdrawn", "to", feeRecipient.String(), "amount", itoa(amount))
}

// SweepDenom sends the surplus of a single denomination to the fee
// recipient (the bounded escape hatch validated on the vault realm).
// For ugnot only the excess over Liabilities() moves; other denoms move
// wholly. Only the fee recipient may call it.
func SweepDenom(cur realm, denom string) {
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may sweep surplus")
	}
	if denom == "" {
		panic("empty denom")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	amount := bk.GetCoin(self, denom)
	if denom == Denom {
		amount -= Liabilities()
	}
	if amount <= 0 {
		panic("no surplus to sweep for " + denom)
	}
	bk.SendCoins(self, feeRecipient, chain.Coins{chain.NewCoin(denom, amount)})
	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", itoa(amount)+denom)
}

// SetFeeBps sets the protocol fee snapshotted into FUTURE bounties at
// creation. Existing bounties keep the fee they were created under.
// Admin only; bounded by [0, MaxFeeBps].
func SetFeeBps(cur realm, bps int64) {
	assertAdmin(cur.Previous().Address())
	if bps < 0 || bps > MaxFeeBps {
		panic("fee bps out of range [0, " + itoa(MaxFeeBps) + "]")
	}
	old := feeBps
	feeBps = bps
	chain.Emit("FeeBpsChanged", "old", itoa(old), "new", itoa(bps))
}

// SetFeeRecipient re-points the fee/surplus role, including the pot
// accrued so far. Admin only; zero address rejected.
func SetFeeRecipient(cur realm, next address) {
	assertAdmin(cur.Previous().Address())
	var zero address
	if next == zero {
		panic("empty fee recipient")
	}
	old := feeRecipient
	feeRecipient = next
	chain.Emit("FeeRecipientChanged", "old", old.String(), "new", next.String())
}

// TransferAdmin hands the admin role to next. Admin only; zero address
// rejected. One-step (documented trade-off, as on the vault).
func TransferAdmin(cur realm, next address) {
	assertAdmin(cur.Previous().Address())
	var zero address
	if next == zero {
		panic("empty admin address")
	}
	admin = next
	chain.Emit("AdminTransferred", "newAdmin", next.String())
}

// --- read-only views ---

// BountyInfo returns a bounty's fields by value: funder, title, amount,
// snapshotted fee bps, status, winner (zero address unless awarded).
func BountyInfo(id int64) (funder address, title string, amount, feeBps int64, status string, winner address) {
	b := mustGetBounty(id)
	return b.funder, b.title, b.amount, b.feeBps, b.status, b.winner
}

// Admin returns the current admin.
func Admin() address { return admin }

// FeeRecipient returns who may withdraw fees and sweep surplus.
func FeeRecipient() address { return feeRecipient }

// FeeBps returns the protocol fee that will be snapshotted into newly
// created bounties (existing bounties keep their own snapshot).
func FeeBps() int64 { return feeBps }

// NumBounties returns how many bounties have ever been created.
func NumBounties() int64 { return nextID }

// OpenTotal returns the escrow held by open bounties (the B term).
func OpenTotal() int64 { return openTotal }

// BalanceOf returns addr's claimable balance (won bounties + refunds).
func BalanceOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// UsersTotal returns the sum of all claimable balances (the U term).
func UsersTotal() int64 { return ledger.UsersTotal() }

// FeesAccrued returns the fee pot (the F term).
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities returns everything this realm owes:
// openTotal + UsersTotal + FeesAccrued.
func Liabilities() int64 { return openTotal + ledger.Liabilities() }

// Held returns the ugnot actually held at the realm address (the H term).
func Held() int64 { return banker.NewReadonlyBanker().GetCoin(self, Denom) }

// Surplus returns Held() - Liabilities() (the S term; >= 0 unless a
// conservation bug exists).
func Surplus() int64 { return Held() - Liabilities() }

// Address returns this realm's address (the escrow target).
func Address() address { return self }

// Render shows configuration, totals, the composed conservation check,
// and the most recent bounties (bounded page, newest first).
func Render(_ string) string {
	held := Held()
	liab := Liabilities()
	status := "OK"
	if held < liab {
		status = "VIOLATED"
	}
	out := "# Bounties\n\n"
	out += "GNOT bounty board; accounting delegated to p/.../feeledger.\n\n"
	out += "## Configuration\n\n"
	out += "- fee on award: " + itoa(feeBps) + " bps (cap " + itoa(MaxFeeBps) + " bps)\n"
	out += "- fee recipient: " + feeRecipient.String() + "\n"
	out += "- admin: " + admin.String() + "\n\n"
	out += "## Accounting (H == B + U + F + S)\n\n"
	out += "- open escrow (B): " + itoa(openTotal) + Denom + "\n"
	out += "- claimable (U): " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- fees accrued (F): " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- held (H): " + itoa(held) + Denom + "\n"
	out += "- conservation: " + status + "\n\n"
	out += "## Latest bounties\n\n"
	if nextID == 0 {
		out += "No bounties yet.\n"
		return out
	}
	shown := 0
	bounties.ReverseIterate("", "", func(_ string, v any) bool {
		b := v.(*bounty)
		out += "- #" + itoa(b.id) + " [" + b.status + "] " + b.title +
			" — " + itoa(b.amount) + Denom + "\n"
		shown++
		return shown >= 20
	})
	return out
}

// --- internals ---

func assertAdmin(caller address) {
	if caller != admin {
		panic("admin only")
	}
}

func mustGetBounty(id int64) *bounty {
	v := bounties.Get(padID(id))
	if v == nil {
		panic("unknown bounty id")
	}
	return v.(*bounty)
}

// assertValidTitle bounds length and restricts the charset so titles
// cannot inject markdown into Render output.
func assertValidTitle(title string) {
	if len(title) == 0 || len(title) > maxTitleLen {
		panic("title must be 1-" + strconv.Itoa(maxTitleLen) + " characters")
	}
	for i := 0; i < len(title); i++ {
		c := title[i]
		switch {
		case c >= 'a' && c <= 'z':
		case c >= 'A' && c <= 'Z':
		case c >= '0' && c <= '9':
		case c == ' ' || c == '_' || c == '-':
		default:
			panic("title may only contain letters, digits, space, _ and -")
		}
	}
}

// padID renders an id as a fixed-width key so avl iteration order is
// numeric order.
func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

// send moves amount ugnot from the realm to `to`. Callers must have
// debited the ledger first (checks-effects-interactions).
func send(cur realm, to address, amount int64) {
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(self, to, chain.Coins{chain.NewCoin(Denom, amount)})
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}

func checkedAdd(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}
