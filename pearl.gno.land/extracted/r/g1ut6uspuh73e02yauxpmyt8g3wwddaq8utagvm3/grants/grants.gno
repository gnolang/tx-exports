// Realm grants is a decentralized grants market: a creator escrows
// GNOT behind a grant with an application deadline, applicants apply
// on-chain, the creator selects one applicant, and the winner claims
// the funding minus a transparent protocol fee.
//
// COMPOSITION (per the recorded DISCOVERY / REUSE ANALYSIS): all
// balance accounting is delegated to feeledger, all coin movement to
// coinio, and all free-text render output to the ecosystem sanitizer
// p/nt/markdown/sanitize/v0. This realm owns only the grants state
// machine: grant records, per-grant applications, open-escrow total,
// deadlines, and roles.
//
// LIFECYCLE (terminal states are frozen; one transition per grant):
//
//	CreateGrant (EOA + -send)     : escrow -> openTotal, status Open,
//	                                fee bps SNAPSHOTTED at creation
//	Apply (also re-apply/update)  : while Open and height < deadline;
//	                                keyed by the caller's own address
//	SelectWinner (creator only)   : Open -> Awarded; winner MUST be an
//	                                applicant; escrow -> winner's
//	                                claimable balance minus the
//	                                snapshotted fee
//	CancelGrant (creator only)    : Open -> Cancelled; fee-free refund
//	                                to the creator's claimable balance
//	ExpireGrant (ANYONE)          : Open -> Expired once height >=
//	                                deadline + ExpiryGraceBlocks;
//	                                fee-free refund to the creator —
//	                                the permissionless valve that makes
//	                                fund-trapping impossible
//	Claim / ClaimAll (anyone)     : pays out the caller's own ledger
//	                                balance (winners and refunds)
//	WithdrawFees (fee recipient)  : pays out the fee pot
//
// AUTHORIZATION: every identity is derived from the crossing
// entrypoint's cur.Previous().Address() — no function takes a caller
// identity as a parameter. Applications and claimable balances are
// keyed by that runtime-derived address, so altering another user's
// application or claiming another user's grant is impossible by
// construction. The creator cannot apply to their own grant, and
// SelectWinner only accepts addresses that actually applied.
//
// DEADLINE SEMANTICS: deadline = ChainHeight() + durationBlocks,
// fixed at creation (bounded by [MinDurationBlocks, MaxDurationBlocks]).
// The deadline gates NEW/UPDATED applications only; the creator may
// select or cancel at any time while the grant is Open. After
// deadline + ExpiryGraceBlocks anyone may expire the grant.
//
// FEE MODEL: fee = floor(amount * bps / 10000), rounding favors the
// winner; no minimum fee; bps snapshotted into the grant at creation,
// so SetFeeBps affects future grants only (closes the AWARD-time
// admin race), and CreateGrant takes the caller's own maxFeeBps
// ceiling, rejecting creation if the live fee exceeds what the
// creator signed for (closes the CREATION-time race — audit Y1);
// hard compile-time cap MaxFeeBps (10%); refunds (cancel/expire) are
// always fee-free; the pot is withdrawable by the fee-recipient role.
//
// MONETARY INVARIANT (conservation): let H be ugnot held at this
// realm's address, G = openTotal (Σ amount over Open grants), U the
// ledger's claimable balances, F the fee pot, S >= 0 out-of-band
// surplus:
//
//	H == G + U + F + S
//
// Every transition moves value between exactly two terms inside one
// transaction: CreateGrant raises H and G together (coinio.Receive is
// the receipt-guaranteed shape, validated live on pearl-1);
// SelectWinner/CancelGrant/ExpireGrant move amount from G into U+F
// with feeledger guaranteeing credited + fee == amount; claims and fee
// withdrawal debit the ledger before coinio.Payout moves the identical
// amount out (checks-effects-interactions); any panic aborts the whole
// transaction; this realm never issues or removes coins. Surplus is
// recoverable only via SweepDenom (fee recipient), which reserves
// Liabilities() = G + U + F.
//
// ONLY GNOT: CreateGrant rejects any envelope that is not exactly one
// positive ugnot coin (coinio.Receive). Foreign denominations sit in
// surplus.
package grants

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Denom is the only asset this realm accepts.
const Denom = "ugnot"

// MaxFeeBps is the hard protocol-fee cap: 1000 bps = 10%.
const MaxFeeBps = int64(1000)

// Grant status values.
const (
	StatusOpen      = "open"
	StatusAwarded   = "awarded"
	StatusCancelled = "cancelled"
	StatusExpired   = "expired"
)

// Input bounds.
const (
	MaxTitleLen = 80
	MaxDescLen  = 2000
	MaxPitchLen = 1000

	// MinDurationBlocks / MaxDurationBlocks bound the application
	// window a creator may configure (~5s blocks: 1 block to ~580 days).
	MinDurationBlocks = int64(1)
	MaxDurationBlocks = int64(10_000_000)

	// ExpiryGraceBlocks after the deadline, an Open grant becomes
	// expirable by anyone (~8 minutes at 5s blocks — short because
	// this is a testnet deployment; a production fork would raise it).
	ExpiryGraceBlocks = int64(100)
)

type application struct {
	pitch  string
	height int64 // block height of the latest (re)submission
}

type grant struct {
	id          int64
	creator     address
	title       string
	description string
	amount      int64
	feeBps      int64 // snapshotted at creation, charged at award
	deadline    int64 // block height; applications close here
	status      string
	winner      address   // set iff status == StatusAwarded
	apps        *avl.Tree // applicant address string -> *application
	numApps     int64
}

var (
	admin        address // may set fee, fee recipient, successor admin
	feeRecipient address // may withdraw fees and sweep surplus
	feeBps       int64   // fee snapshotted into NEW grants

	self      address // this realm's address, captured at deploy
	nextID    int64
	openTotal int64 // == Σ amount over grants with status Open

	grants = avl.NewTree() // padID(id) -> *grant
	ledger = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// CreateGrant escrows the attached GNOT as a new open grant and
// returns its id. Only direct EOA calls with -send are accepted. The
// current protocol fee is snapshotted into the grant — and must not
// exceed maxFeeBps, the ceiling the caller signed for (rejects a fee
// raise sequenced ahead of this transaction); pass MaxFeeBps to
// accept any legal fee. The application window is durationBlocks from
// now.
func CreateGrant(cur realm, title, description string, durationBlocks, maxFeeBps int64) int64 {
	creator, amount := coinio.Receive(0, cur, Denom)
	if feeBps > maxFeeBps {
		panic("current fee " + itoa(feeBps) + " bps exceeds the caller's maximum " + itoa(maxFeeBps))
	}
	assertValidTitle(title)
	if len(description) == 0 || len(description) > MaxDescLen {
		panic("description must be 1-" + strconv.Itoa(MaxDescLen) + " bytes")
	}
	if durationBlocks < MinDurationBlocks || durationBlocks > MaxDurationBlocks {
		panic("durationBlocks out of range [" + itoa(MinDurationBlocks) + ", " + itoa(MaxDurationBlocks) + "]")
	}

	newOpenTotal, ok := checkedAdd(openTotal, amount)
	if !ok {
		panic("open escrow overflow")
	}

	nextID++
	g := &grant{
		id:          nextID,
		creator:     creator,
		title:       title,
		description: description,
		amount:      amount,
		feeBps:      feeBps,
		deadline:    runtime.ChainHeight() + durationBlocks,
		status:      StatusOpen,
		apps:        avl.NewTree(),
	}
	grants.Set(padID(g.id), g)
	openTotal = newOpenTotal

	chain.Emit("GrantCreated",
		"id", itoa(g.id),
		"creator", creator.String(),
		"amount", itoa(amount),
		"feeBps", itoa(g.feeBps),
		"deadline", itoa(g.deadline),
	)
	return g.id
}

// Apply submits (or re-submits) the caller's application to an open
// grant before its deadline. One application per address per grant —
// re-applying replaces the caller's own pitch only. The creator cannot
// apply to their own grant.
func Apply(cur realm, id int64, pitch string) {
	applicant := cur.Previous().Address()
	g := mustGetGrant(id)
	if g.status != StatusOpen {
		panic("grant is not open")
	}
	if runtime.ChainHeight() >= g.deadline {
		panic("application deadline has passed")
	}
	if applicant == g.creator {
		panic("the creator cannot apply to their own grant")
	}
	if len(pitch) == 0 || len(pitch) > MaxPitchLen {
		panic("pitch must be 1-" + strconv.Itoa(MaxPitchLen) + " bytes")
	}

	key := applicant.String()
	if g.apps.Get(key) == nil {
		g.numApps++
	}
	g.apps.Set(key, &application{pitch: pitch, height: runtime.ChainHeight()})

	chain.Emit("Applied", "id", itoa(id), "applicant", key)
}

// SelectWinner awards an open grant to one of its applicants: the
// escrow leaves the open pool and is credited to the winner's
// claimable balance through the ledger, charging the fee snapshotted
// at creation. Only the grant's creator may select, and only an
// address that actually applied can win. Terminal.
func SelectWinner(cur realm, id int64, winner address) {
	caller := cur.Previous().Address()
	g := mustGetGrant(id)
	if caller != g.creator {
		panic("only the grant creator may select a winner")
	}
	if g.status != StatusOpen {
		panic("grant is not open")
	}
	if g.apps.Get(winner.String()) == nil {
		panic("winner must be an applicant of this grant")
	}

	// Move the escrow from application state into ledger liabilities in
	// one transaction, at the snapshotted fee. feeledger validates
	// before mutating; an error aborts everything and leaves the grant
	// Open (the creator can retry or cancel).
	credited, fee, err := ledger.Deposit(winner.String(), g.amount, g.feeBps)
	if err != nil {
		panic(err)
	}
	openTotal -= g.amount // >= 0: openTotal == Σ open amounts >= g.amount
	g.status = StatusAwarded
	g.winner = winner

	chain.Emit("GrantAwarded",
		"id", itoa(id),
		"winner", winner.String(),
		"credited", itoa(credited),
		"fee", itoa(fee),
	)
}

// CancelGrant closes an open grant and refunds its escrow to the
// creator's claimable balance, fee-free. Only the creator may cancel.
// Terminal.
func CancelGrant(cur realm, id int64) {
	caller := cur.Previous().Address()
	g := mustGetGrant(id)
	if caller != g.creator {
		panic("only the grant creator may cancel")
	}
	if g.status != StatusOpen {
		panic("grant is not open")
	}
	refundOpen(g, StatusCancelled)
	chain.Emit("GrantCancelled", "id", itoa(id), "creator", g.creator.String(), "amount", itoa(g.amount))
}

// ExpireGrant closes an open grant whose deadline passed more than
// ExpiryGraceBlocks ago, refunding the creator fee-free. ANYONE may
// call it — this is the permissionless valve that guarantees escrow
// can never be trapped by an inactive creator. Terminal.
func ExpireGrant(cur realm, id int64) {
	g := mustGetGrant(id)
	if g.status != StatusOpen {
		panic("grant is not open")
	}
	if runtime.ChainHeight() < g.deadline+ExpiryGraceBlocks {
		panic("grant is not expirable yet")
	}
	refundOpen(g, StatusExpired)
	chain.Emit("GrantExpired", "id", itoa(g.id), "creator", g.creator.String(), "amount", itoa(g.amount))
}

// refundOpen moves an Open grant's escrow into the creator's claimable
// balance fee-free and finalizes the status. Callers have already
// verified authorization and status.
func refundOpen(g *grant, terminal string) {
	if _, _, err := ledger.Deposit(g.creator.String(), g.amount, 0); err != nil {
		panic(err)
	}
	openTotal -= g.amount
	g.status = terminal
}

// Claim sends amount ugnot of the caller's claimable balance (won
// grants and refunds) back to the caller.
func Claim(cur realm, amount int64) {
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
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
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// WithdrawFees sends the accrued fee pot to the fee recipient. Only
// the fee recipient may call it.
func WithdrawFees(cur realm) {
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may withdraw fees")
	}
	if ledger.FeesAccrued() == 0 {
		panic("no fees accrued")
	}
	amount := ledger.WithdrawFees()
	coinio.Payout(0, cur, feeRecipient, Denom, amount)
	chain.Emit("FeesWithdrawn", "to", feeRecipient.String(), "amount", itoa(amount))
}

// SweepDenom sends the surplus of a single denomination to the fee
// recipient. For ugnot only the excess over Liabilities() moves; other
// denoms move wholly. Only the fee recipient may call it.
func SweepDenom(cur realm, denom string) {
	caller := cur.Previous().Address()
	if caller != feeRecipient {
		panic("only the fee recipient may sweep surplus")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = Liabilities()
	}
	swept := coinio.Sweep(0, cur, feeRecipient, denom, reserve)
	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", itoa(swept)+denom)
}

// SetFeeBps sets the protocol fee snapshotted into FUTURE grants at
// creation. Existing grants keep the fee they were created under.
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
// rejected. One-step (documented trade-off).
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

// GrantInfo returns a grant's fields by value: creator, title, amount,
// snapshotted fee bps, application deadline (block height), status,
// winner (zero unless awarded), and number of applicants.
func GrantInfo(id int64) (creator address, title string, amount, feeBps, deadline int64, status string, winner address, numApplicants int64) {
	g := mustGetGrant(id)
	return g.creator, g.title, g.amount, g.feeBps, g.deadline, g.status, g.winner, g.numApps
}

// Description returns a grant's raw description text.
func Description(id int64) string { return mustGetGrant(id).description }

// ApplicationOf returns addr's pitch and submission height for a
// grant, with ok reporting whether an application exists.
func ApplicationOf(id int64, addr address) (pitch string, height int64, ok bool) {
	g := mustGetGrant(id)
	v := g.apps.Get(addr.String())
	if v == nil {
		return "", 0, false
	}
	a := v.(*application)
	return a.pitch, a.height, true
}

// Admin returns the current admin.
func Admin() address { return admin }

// FeeRecipient returns who may withdraw fees and sweep surplus.
func FeeRecipient() address { return feeRecipient }

// FeeBps returns the fee that will be snapshotted into newly created
// grants (existing grants keep their own snapshot).
func FeeBps() int64 { return feeBps }

// FeeOn previews the fee and net payout for a grant of amount at the
// CURRENT FeeBps.
func FeeOn(amount int64) (fee, credited int64) {
	f, err := feeledger.FeeFor(amount, feeBps)
	if err != nil {
		panic(err)
	}
	return f, amount - f
}

// NumGrants returns how many grants have ever been created.
func NumGrants() int64 { return nextID }

// OpenTotal returns the escrow held by open grants (the G term).
func OpenTotal() int64 { return openTotal }

// BalanceOf returns addr's claimable balance (won grants + refunds).
func BalanceOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// UsersTotal returns the sum of all claimable balances (the U term).
func UsersTotal() int64 { return ledger.UsersTotal() }

// FeesAccrued returns the fee pot (the F term).
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities returns everything this realm owes:
// openTotal + UsersTotal + FeesAccrued.
func Liabilities() int64 { return openTotal + ledger.Liabilities() }

// Held returns the ugnot actually held at the realm address (H).
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus returns Held() - Liabilities() (the S term).
func Surplus() int64 { return Held() - Liabilities() }

// Address returns this realm's address (the escrow target).
func Address() address { return self }

// Height returns the current chain height (deadline arithmetic aid).
func Height() int64 { return runtime.ChainHeight() }

// Render shows the market at "" and a grant detail at "<id>". Free
// text (titles are charset-restricted; descriptions are not) passes
// through the ecosystem sanitizer before hitting markdown.
func Render(path string) string {
	if path != "" {
		return renderGrant(path)
	}
	held := Held()
	liab := Liabilities()
	status := "OK"
	if held < liab {
		status = "VIOLATED"
	}
	out := "# Grants market\n\n"
	out += "Escrowed GNOT grants with on-chain applications; accounting via feeledger, coin I/O via coinio.\n\n"
	out += "## Configuration\n\n"
	out += "- fee for new grants: " + itoa(feeBps) + " bps (cap " + itoa(MaxFeeBps) +
		" bps; each grant keeps the fee snapshotted at its creation)\n"
	out += "- fee recipient: " + feeRecipient.String() + "\n"
	out += "- admin: " + admin.String() + "\n\n"
	out += "## Accounting (H == G + U + F + S)\n\n"
	out += "- open escrow (G): " + itoa(openTotal) + Denom + "\n"
	out += "- claimable (U): " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- fees accrued (F): " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- held (H): " + itoa(held) + Denom + "\n"
	out += "- conservation: " + status + "\n\n"
	out += "## Latest grants\n\n"
	if nextID == 0 {
		out += "No grants yet.\n"
		return out
	}
	shown := 0
	grants.ReverseIterate("", "", func(_ string, v any) bool {
		g := v.(*grant)
		out += "- [#" + itoa(g.id) + "](" + "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/grants:" + itoa(g.id) + ") [" +
			g.status + "] " + g.title + " — " + itoa(g.amount) + Denom +
			" (" + itoa(g.numApps) + " applicants)\n"
		shown++
		return shown >= 20
	})
	return out
}

func renderGrant(path string) string {
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid grant id\n"
	}
	v := grants.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown grant id\n"
	}
	g := v.(*grant)
	out := "# Grant #" + itoa(g.id) + ": " + g.title + "\n\n"
	out += "- status: " + g.status + "\n"
	out += "- creator: " + g.creator.String() + "\n"
	out += "- amount: " + itoa(g.amount) + Denom + "\n"
	out += "- fee (snapshot): " + itoa(g.feeBps) + " bps\n"
	out += "- application deadline: block " + itoa(g.deadline) + " (now " + itoa(runtime.ChainHeight()) + ")\n"
	out += "- applicants: " + itoa(g.numApps) + "\n"
	if g.status == StatusAwarded {
		out += "- winner: " + g.winner.String() + "\n"
	}
	out += "\n## Description\n\n" + sanitize.InlineText(g.description) + "\n"
	return out
}

// --- internals ---

func assertAdmin(caller address) {
	if caller != admin {
		panic("admin only")
	}
}

func mustGetGrant(id int64) *grant {
	v := grants.Get(padID(id))
	if v == nil {
		panic("unknown grant id")
	}
	return v.(*grant)
}

// assertValidTitle bounds length and restricts the charset so titles
// are list-safe in Render without escaping.
func assertValidTitle(title string) {
	if len(title) == 0 || len(title) > MaxTitleLen {
		panic("title must be 1-" + strconv.Itoa(MaxTitleLen) + " characters")
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
