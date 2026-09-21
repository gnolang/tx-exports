// Realm market is a custodial GNOT marketplace for goods listings:
// sellers list (title, description, price), a buyer purchases by
// paying the exact price, the marketplace holds the value until the
// seller claims their proceeds (price minus a transparent, snapshotted
// protocol fee).
//
// COMPOSITION (per the recorded DISCOVERY / REUSE ANALYSIS): balance
// accounting is feeledger, coin movement is coinio, free-text render
// safety is the ecosystem sanitizer p/nt/markdown/sanitize/v0. This
// realm owns only the listing state machine. Two patterns are adopted
// from inspected ecosystem marketplaces: non-payable entrypoints
// REFUSE accidental -send instead of stranding it as surplus
// (nsmarket/v4's assertNoSend), and admin handoff is 2-STEP
// (memba_appstore_v2's TransferOwnership/AcceptOwnership), closing the
// one-step-transfer trade-off carried by earlier realms.
//
// LIFECYCLE (terminal states are frozen; one transition per listing):
//
//	CreateListing (anyone, no coins) : status Active; the fee bps is
//	                                   SNAPSHOTTED, subject to the
//	                                   seller's own maxFeeBps ceiling
//	Buy (EOA + -send == price)       : Active -> Sold, atomically:
//	                                   proceeds (price - snapshot fee)
//	                                   credit the seller's claimable
//	                                   balance, the fee accrues to the
//	                                   pot, the buyer is recorded
//	CancelListing (seller only)      : Active -> Cancelled (no funds
//	                                   are involved; listings hold no
//	                                   value)
//	Claim / ClaimAll (anyone)        : pays out the caller's own
//	                                   claimable proceeds
//	WithdrawFees (fee recipient)     : pays out the fee pot
//
// LISTINGS ARE IMMUTABLE: there is no price update — cancel and relist
// (new id). Together with Buy's EXACT-envelope rule this closes the
// listing-manipulation race twice over: a cancelled/relisted listing
// fails Buy's status check, and any price change fails the envelope
// check — either way the buyer's coins revert with the transaction.
// Buyers are structurally indifferent to fee changes: they pay the
// listed price; the fee comes out of the seller's proceeds at the bps
// snapshotted when the SELLER listed (with the seller's own ceiling —
// the creation-time fee race is closed the same way grants closes it).
//
// AUTHORIZATION: every identity derives from the crossing entrypoint's
// cur.Previous().Address(); no function takes a caller identity as a
// parameter. Sellers may be EOAs or realms (they claim under their own
// address); buyers must be EOAs (coinio.Receive is the
// receipt-guaranteed shape). Self-purchase is rejected.
//
// REALM-SELLER CAVEAT (audit Y1): assertNoSend reads the ORIGIN
// transaction's send envelope, so a realm seller must call
// CreateListing/CancelListing/Claim* in a transaction whose origin
// carried no -send — otherwise the guard fails closed even though this
// realm received nothing. Not third-party triggerable (nobody can
// attach a send to someone else's transaction); the workaround is a
// separate transaction.
//
// MONETARY INVARIANT (conservation): listings hold NO value, so with
// H = ugnot held at the realm address, U = claimable seller proceeds,
// F = the fee pot, S >= 0 out-of-band surplus:
//
//	H == U + F + S
//
// Buy raises H by exactly price and U+F by exactly price (feeledger
// guarantees credited + fee == amount); Claim*/WithdrawFees debit the
// ledger before coinio.Payout moves the identical amount out; any
// panic aborts the whole transaction; this realm never issues or
// removes coins. Surplus is recoverable only via SweepDenom (fee
// recipient), which reserves Liabilities() = U + F.
//
// APPLICATION INVARIANT: status transitions Active -> {Sold,
// Cancelled} exactly once; Sold if and only if a buyer is recorded;
// for every sold listing, proceeds + fee == price at the snapshotted
// bps.
package market

import (
	"chain"
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

// Listing status values.
const (
	StatusActive    = "active"
	StatusSold      = "sold"
	StatusCancelled = "cancelled"
)

// Input bounds.
const (
	MaxTitleLen = 80
	MaxDescLen  = 2000
	MinPrice    = int64(1)
)

type listing struct {
	id          int64
	seller      address
	title       string
	description string
	price       int64
	feeBps      int64 // snapshotted at creation, charged at Buy
	status      string
	buyer       address // set iff status == StatusSold
}

var (
	admin        address // may set fee, fee recipient, stage successor
	pendingAdmin address // staged by TransferAdmin, completes via AcceptAdmin
	feeRecipient address // may withdraw fees and sweep surplus
	feeBps       int64   // fee snapshotted into NEW listings

	self   address // this realm's address, captured at deploy
	nextID int64

	listings = avl.NewTree() // padID(id) -> *listing
	ledger   = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// CreateListing publishes an immutable listing and returns its id. No
// coins are accepted (the storage deposit the caller pays is the
// anti-spam). The current protocol fee is snapshotted into the listing
// and must not exceed maxFeeBps, the ceiling the seller signed for;
// pass MaxFeeBps to accept any legal fee. Sellers may be EOAs or
// realms.
func CreateListing(cur realm, title, description string, price, maxFeeBps int64) int64 {
	assertNoSend()
	seller := cur.Previous().Address()
	if feeBps > maxFeeBps {
		panic("current fee " + itoa(feeBps) + " bps exceeds the seller's maximum " + itoa(maxFeeBps))
	}
	assertValidTitle(title)
	if len(description) == 0 || len(description) > MaxDescLen {
		panic("description must be 1-" + strconv.Itoa(MaxDescLen) + " bytes")
	}
	if price < MinPrice {
		panic("price must be at least " + itoa(MinPrice) + Denom)
	}

	nextID++
	l := &listing{
		id:          nextID,
		seller:      seller,
		title:       title,
		description: description,
		price:       price,
		feeBps:      feeBps,
		status:      StatusActive,
	}
	listings.Set(padID(l.id), l)

	chain.Emit("ListingCreated",
		"id", itoa(l.id),
		"seller", seller.String(),
		"price", itoa(price),
		"feeBps", itoa(l.feeBps),
	)
	return l.id
}

// Buy purchases an active listing. The buyer must be a direct EOA
// caller and attach EXACTLY the listed price in ugnot — any mismatch
// (including a price the seller changed by cancel-and-relist) aborts
// and the coins revert with the transaction. Settlement is atomic:
// the seller's proceeds (price minus the snapshotted fee) become
// claimable, the fee accrues to the pot, and the buyer is recorded.
// Terminal.
func Buy(cur realm, id int64) {
	buyer, amount := coinio.Receive(0, cur, Denom)
	l := mustGetListing(id)
	if l.status != StatusActive {
		panic("listing is not active")
	}
	if buyer == l.seller {
		panic("the seller cannot buy their own listing")
	}
	if amount != l.price {
		panic("send exactly the listed price: " + itoa(l.price) + Denom)
	}

	// Move the purchase into ledger liabilities in one transaction, at
	// the fee snapshotted when the seller listed. feeledger validates
	// before mutating; an error aborts everything and the listing
	// stays Active.
	proceeds, fee, err := ledger.Deposit(l.seller.String(), l.price, l.feeBps)
	if err != nil {
		panic(err)
	}
	l.status = StatusSold
	l.buyer = buyer

	chain.Emit("Sold",
		"id", itoa(id),
		"seller", l.seller.String(),
		"buyer", buyer.String(),
		"price", itoa(l.price),
		"proceeds", itoa(proceeds),
		"fee", itoa(fee),
	)
}

// CancelListing withdraws an active listing. Only the seller may
// cancel; no funds are involved. Terminal.
func CancelListing(cur realm, id int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	l := mustGetListing(id)
	if caller != l.seller {
		panic("only the seller may cancel")
	}
	if l.status != StatusActive {
		panic("listing is not active")
	}
	l.status = StatusCancelled

	chain.Emit("ListingCancelled", "id", itoa(id), "seller", l.seller.String())
}

// Claim sends amount ugnot of the caller's claimable proceeds back to
// the caller.
func Claim(cur realm, amount int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire claimable proceeds back to the
// caller. Fails if there is nothing to claim.
func ClaimAll(cur realm) {
	assertNoSend()
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
	assertNoSend()
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
	assertNoSend()
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

// SetFeeBps sets the protocol fee snapshotted into FUTURE listings.
// Existing listings keep the fee they were created under. Admin only;
// bounded by [0, MaxFeeBps].
func SetFeeBps(cur realm, bps int64) {
	assertNoSend()
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
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	var zero address
	if next == zero {
		panic("empty fee recipient")
	}
	old := feeRecipient
	feeRecipient = next
	chain.Emit("FeeRecipientChanged", "old", old.String(), "new", next.String())
}

// TransferAdmin STAGES a successor admin; the handoff completes only
// when that address calls AcceptAdmin (2-step, so a typo cannot brick
// administration — pattern adopted from memba_appstore_v2). Admin
// only; zero address rejected. Re-staging overwrites a previous stage.
func TransferAdmin(cur realm, next address) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	var zero address
	if next == zero {
		panic("empty admin address")
	}
	pendingAdmin = next
	chain.Emit("AdminTransferStaged", "pending", next.String())
}

// AcceptAdmin completes a staged admin handoff. Only the staged
// address may call it.
func AcceptAdmin(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	var zero address
	if pendingAdmin == zero || caller != pendingAdmin {
		panic("caller is not the staged admin")
	}
	admin = pendingAdmin
	pendingAdmin = zero
	chain.Emit("AdminTransferred", "newAdmin", admin.String())
}

// --- read-only views ---

// ListingInfo returns a listing's fields by value: seller, title,
// price, snapshotted fee bps, status, and buyer (zero unless sold).
func ListingInfo(id int64) (seller address, title string, price, feeBps int64, status string, buyer address) {
	l := mustGetListing(id)
	return l.seller, l.title, l.price, l.feeBps, l.status, l.buyer
}

// Description returns a listing's raw description text.
func Description(id int64) string { return mustGetListing(id).description }

// Quote returns what a buyer pays and what the seller would receive
// for a listing, at its SNAPSHOTTED fee — the same arithmetic Buy
// performs (pattern from nsmarket/v4: a fee discovered after signing
// is a fee the seller was not told about).
func Quote(id int64) (price, fee, toSeller int64) {
	l := mustGetListing(id)
	f, err := feeledger.FeeFor(l.price, l.feeBps)
	if err != nil {
		panic(err)
	}
	return l.price, f, l.price - f
}

// Admin returns the current admin.
func Admin() address { return admin }

// PendingAdmin returns the staged successor (zero when none).
func PendingAdmin() address { return pendingAdmin }

// FeeRecipient returns who may withdraw fees and sweep surplus.
func FeeRecipient() address { return feeRecipient }

// FeeBps returns the fee that will be snapshotted into newly created
// listings (existing listings keep their own snapshot).
func FeeBps() int64 { return feeBps }

// NumListings returns how many listings have ever been created.
func NumListings() int64 { return nextID }

// BalanceOf returns addr's claimable proceeds.
func BalanceOf(addr address) int64 { return ledger.BalanceOf(addr.String()) }

// UsersTotal returns the sum of all claimable proceeds (the U term).
func UsersTotal() int64 { return ledger.UsersTotal() }

// FeesAccrued returns the fee pot (the F term).
func FeesAccrued() int64 { return ledger.FeesAccrued() }

// Liabilities returns everything this realm owes: UsersTotal +
// FeesAccrued (listings hold no value by construction).
func Liabilities() int64 { return ledger.Liabilities() }

// Held returns the ugnot actually held at the realm address (H).
func Held() int64 { return coinio.HeldAt(self, Denom) }

// Surplus returns Held() - Liabilities() (the S term).
func Surplus() int64 { return Held() - ledger.Liabilities() }

// Address returns this realm's address.
func Address() address { return self }

// Render shows the market at "" and a listing detail at "<id>".
// Titles are charset-restricted; descriptions pass through the
// ecosystem sanitizer.
func Render(path string) string {
	if path != "" {
		return renderListing(path)
	}
	held := Held()
	liab := ledger.Liabilities()
	status := "OK"
	if held < liab {
		status = "VIOLATED"
	}
	out := "# Marketplace\n\n"
	out += "Custodial GNOT marketplace; accounting via feeledger, coin I/O via coinio.\n\n"
	out += "## Configuration\n\n"
	out += "- fee for new listings: " + itoa(feeBps) + " bps (cap " + itoa(MaxFeeBps) +
		" bps; each listing keeps the fee snapshotted at its creation)\n"
	out += "- fee recipient: " + feeRecipient.String() + "\n"
	out += "- admin: " + admin.String() + "\n\n"
	out += "## Accounting (H == U + F + S; listings hold no value)\n\n"
	out += "- claimable proceeds (U): " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- fees accrued (F): " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- held (H): " + itoa(held) + Denom + "\n"
	out += "- conservation: " + status + "\n\n"
	out += "## Latest listings\n\n"
	if nextID == 0 {
		out += "No listings yet.\n"
		return out
	}
	shown := 0
	listings.ReverseIterate("", "", func(_ string, v any) bool {
		l := v.(*listing)
		out += "- [#" + itoa(l.id) + "](" + "/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/market:" + itoa(l.id) + ") [" +
			l.status + "] " + l.title + " — " + itoa(l.price) + Denom + "\n"
		shown++
		return shown >= 20
	})
	return out
}

func renderListing(path string) string {
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil {
		return "> [!WARNING]\n> invalid listing id\n"
	}
	v := listings.Get(padID(id))
	if v == nil {
		return "> [!WARNING]\n> unknown listing id\n"
	}
	l := v.(*listing)
	out := "# Listing #" + itoa(l.id) + ": " + l.title + "\n\n"
	out += "- status: " + l.status + "\n"
	out += "- seller: " + l.seller.String() + "\n"
	out += "- price: " + itoa(l.price) + Denom + "\n"
	out += "- fee (snapshot): " + itoa(l.feeBps) + " bps\n"
	if l.status == StatusSold {
		out += "- buyer: " + l.buyer.String() + "\n"
	}
	out += "\n## Description\n\n" + sanitize.InlineText(l.description) + "\n"
	return out
}

// --- internals ---

// assertNoSend refuses coins on non-payable entrypoints: an accidental
// -send would otherwise strand at the realm as sweep-only surplus
// (pattern from nsmarket/v4). Buy is the only payable function.
// NOTE: this reads the ORIGIN envelope — for EOA callers that is
// exactly "coins that landed here"; for realm callers it fails closed
// whenever the origin tx carried any -send (see the header caveat).
func assertNoSend() {
	if len(unsafe.OriginSend()) != 0 {
		panic("this function does not accept coins")
	}
}

func assertAdmin(caller address) {
	if caller != admin {
		panic("admin only")
	}
}

func mustGetListing(id int64) *listing {
	v := listings.Get(padID(id))
	if v == nil {
		panic("unknown listing id")
	}
	return v.(*listing)
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
