// Realm auction is an ascending (English) auction settled in ugnot, holding
// real coins. A SELLER lists a lot with a reserve price and a duration;
// BIDDERS raise each other by attaching coins; the standing high bid is
// escrowed by the realm and every OUTBID bid becomes a pull-claimable refund;
// at close the winner's payment is credited to the seller, the protocol fee
// splitting off at the ledger. A bid landing inside the anti-snipe window
// extends the end, so the auction closes only when bidding actually stops.
//
// It is the one market shape this portfolio never had: COMPETITIVE PRICE
// DISCOVERY with escrowed settlement. The routing realms move a known amount
// to known parties (r/fee_split, r/revshare), the disbursement realms pay a
// known total out on a schedule (r/vesting, r/payroll, r/budgets), the credit
// realm lends principal out and takes a larger total back (r/loans), and
// r/crowdfund POOLS many contributions toward one shared goal. An auction is
// none of those: N rival bidders, one escrowed winner, automatic refunds for
// the rest, and a price nobody knows in advance. See [DISCOVERY.md].
//
// # Custody — the conservation invariant is the product
//
// A custodial realm, so the monetary invariant governs it exactly as it does
// r/loans and r/subscriptions, with one extra bucket for the escrowed bids:
//
//	Held == locked + feeledger.Liabilities()
//
// where `locked` is the sum of the CURRENT high bids across all open auctions
// (coins the realm holds but that are not yet claimable by anyone), and the
// ledger holds the two claimable kinds — OUTBID refunds and, after close,
// SELLER proceeds — plus the fee pot. Every value transition preserves the
// equality; see the DELTA-form conservation test.
//
// Refunds are PULL, never push: an outbid bid is credited to the bidder's
// claimable balance (fee 0 — a refund is a full return, not a fee event) and
// the bidder withdraws it with [Claim]. Nothing is sent to a third party
// during someone else's Bid, so a bid cannot be griefed by a hostile previous
// bidder and there is no cross-call reentrancy surface in the bid path.
//
// # What the realm settles, and what it does NOT
//
// The realm settles PAYMENT and records the WINNER; it does not custody or
// deliver the lot, which is identified by a free-text description and changes
// hands off-chain (or by a downstream realm reading [Winner]). This is the
// scope decision, stated rather than discovered: an on-chain-asset auction
// (grc20/grc721 custody) is a v2, and it is exactly the escrow-of-the-asset
// surface this v1 deliberately omits. A winner pays and is recorded; delivery
// is the parties' concern, as it is for r/loans' off-chain use of principal.
//
// REALM-CALLER CAVEAT, inherited from the siblings: coinio's receipt guard
// admits only EOA payers, so every BIDDER is an EOA. The SELLER is whoever
// calls [CreateAuction]; a realm may create an auction, but like revshare's
// members a realm seller must expose its own crossing path to [Claim] or its
// proceeds strand — the seller's concern, not a realm or third-party hazard.
// assertNoSend reads the ORIGIN envelope, so every non-payable function
// refuses any transaction that attached coins anywhere.
package auction

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

// MaxFeeBps is the hard protocol-fee cap: 1000 bps = 10%. The fee applies only
// to the WINNER's payment at close, never to a refund.
const MaxFeeBps = int64(1000)

// Auction status values. Settled, Closed and Cancelled are terminal.
const (
	AuctionOpen      = "open"      // accepting bids until endHeight
	AuctionSettled   = "settled"   // closed WITH a winner; proceeds credited
	AuctionClosed    = "closed"    // closed with NO bids; nothing to settle
	AuctionCancelled = "cancelled" // seller cancelled before any bid
)

// MinIncrementBps is the minimum raise over the standing high bid: 500 = 5%.
// It stops penny-increment griefing without a per-auction knob.
const MinIncrementBps = int64(500)

// Input bounds.
const (
	// MinBid is the dust floor for any bid and any non-zero reserve; MaxBid
	// keeps every bid, the increment and the fee split far from int64
	// overflow. The bidder must ATTACH the bid, so the real ceiling is their
	// balance.
	MinBid = int64(1_000)
	MaxBid = int64(1_000_000_000_000) // 1,000,000 GNOT

	// Duration and anti-snipe bounds, in blocks. The floor keeps an auction
	// off a one-block treadmill; the ceiling keeps height arithmetic far from
	// overflow. A 0 anti-snipe window disables the extension.
	MinDuration  = int64(10)
	MaxDuration  = int64(7_500_000)
	MaxAntiSnipe = int64(7_500_000)

	// MaxLotLen bounds the stored lot description.
	MaxLotLen = 200

	// MaxAuctionsPerSeller bounds one seller's stored auctions; terminal
	// auctions do NOT free the slot, because a settled/closed/cancelled
	// auction is a permanent record a bidder and auditor may need to read.
	MaxAuctionsPerSeller = 50

	// RenderLimit bounds every rendered list — an unbounded Render was YELLOW
	// in three prior audits.
	RenderLimit = 20
)

type auction struct {
	id            int64
	seller        address
	lot           string // free-text description of the lot (delivery is off-chain)
	reserve       int64  // first bid must meet max(reserve, MinBid)
	antiSnipe     int64  // a bid within this many blocks of end extends end to now+antiSnipe
	feeBps        int64  // snapshot at create; applied to the winner's payment at close
	endHeight     int64
	highBid       int64
	highBidder    address // "" until the first bid
	status        string
	createdHeight int64
}

var (
	admin        address
	pendingAdmin address
	feeRecipient address
	feeBps       int64 // snapshotted into NEW auctions

	self   address
	nextID int64
	locked int64 // Σ current high bids of OPEN auctions (held, not yet claimable)

	auctions  = avl.NewTree() // padID(id)       -> *auction
	sellerNum = avl.NewTree() // seller.String() -> *int64, stored auctions
	ledger    = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// --- seller side ---

// CreateAuction lists a lot for ascending-bid sale. The caller becomes the
// seller. `reserve` is 0 (no reserve) or a floor in [MinBid, MaxBid] the first
// bid must meet; the auction runs for `durationBlocks` blocks; a bid landing
// within `antiSnipe` blocks of the end extends the end to now+antiSnipe (0
// disables). The current protocol fee is snapshotted in. Returns the id.
func CreateAuction(cur realm, lot string, reserve, durationBlocks, antiSnipe int64) int64 {
	assertNoSend()
	seller := cur.Previous().Address()
	if len(lot) == 0 || len(lot) > MaxLotLen {
		panic("lot description must be 1.." + itoa(MaxLotLen) + " bytes")
	}
	if reserve != 0 && (reserve < MinBid || reserve > MaxBid) {
		panic("reserve must be 0 or " + itoa(MinBid) + ".." + itoa(MaxBid) + Denom)
	}
	if durationBlocks < MinDuration || durationBlocks > MaxDuration {
		panic("durationBlocks must be " + itoa(MinDuration) + ".." + itoa(MaxDuration))
	}
	if antiSnipe < 0 || antiSnipe > MaxAntiSnipe {
		panic("antiSnipe must be 0.." + itoa(MaxAntiSnipe))
	}

	n := counter(sellerNum, seller)
	if *n >= MaxAuctionsPerSeller {
		panic("per-seller auction limit reached")
	}

	now := runtime.ChainHeight()
	end, ok := addChecked(now, durationBlocks)
	if !ok {
		panic("end-height overflow")
	}
	id := nextID
	nextID++
	auctions.Set(padID(id), &auction{
		id:            id,
		seller:        seller,
		lot:           lot,
		reserve:       reserve,
		antiSnipe:     antiSnipe,
		feeBps:        feeBps,
		endHeight:     end,
		highBidder:    "",
		status:        AuctionOpen,
		createdHeight: now,
	})
	*n++

	chain.Emit("AuctionCreated",
		"auctionId", itoa(id),
		"seller", seller.String(),
		"reserve", itoa(reserve),
		"endHeight", itoa(end),
		"antiSnipe", itoa(antiSnipe),
		"feeBps", itoa(feeBps),
	)
	return id
}

// Cancel withdraws an auction that has not yet received a bid. Seller only.
// Once any bid stands, the auction can only run to close — a seller cannot
// pull the lot out from under a committed bidder.
func Cancel(cur realm, auctionID int64) {
	assertNoSend()
	a := mustAuction(auctionID)
	if cur.Previous().Address() != a.seller {
		panic("only the seller may cancel")
	}
	if a.status != AuctionOpen {
		panic("auction is " + a.status)
	}
	if a.highBidder != "" {
		panic("cannot cancel after a bid")
	}
	a.status = AuctionCancelled
	chain.Emit("AuctionCancelled", "auctionId", itoa(auctionID), "seller", a.seller.String())
}

// --- bidder side ---

// Bid raises the standing high bid on an open auction. The caller attaches the
// bid; it must beat the current high bid by at least MinIncrementBps (or meet
// max(reserve, MinBid) if it is the first bid), and the auction must still be
// open and before its end. The previous high bidder's escrowed bid becomes a
// pull-claimable refund. A bid inside the anti-snipe window extends the end.
func Bid(cur realm, auctionID int64) {
	bidder, amount := coinio.Receive(0, cur, Denom)
	a := mustAuction(auctionID)
	if a.status != AuctionOpen {
		panic("auction is " + a.status)
	}
	now := runtime.ChainHeight()
	if now >= a.endHeight {
		panic("auction has ended; call Close")
	}
	if bidder == a.seller {
		panic("seller cannot bid on their own auction")
	}
	if amount > MaxBid {
		panic("bid exceeds the maximum " + itoa(MaxBid) + Denom)
	}
	min := minNextBid(a)
	if amount < min {
		panic("bid " + itoa(amount) + " is below the minimum next bid " + itoa(min) + Denom)
	}

	// Refund the previous high bidder (pull), then relock at the new high bid.
	// coinio already received `amount`, so Held rose by amount; moving the old
	// high bid from `locked` into the ledger and locking the new one keeps
	// Held == locked + Liabilities exactly.
	if a.highBidder != "" {
		ledger.MustDeposit(a.highBidder.String(), a.highBid, 0)
		locked -= a.highBid
	}
	locked += amount

	a.highBid = amount
	a.highBidder = bidder

	extended := false
	if a.antiSnipe > 0 && a.endHeight-now < a.antiSnipe {
		// Checked like the create-time end (overflow is unreachable under the
		// height bounds, but the checked-arithmetic rule holds everywhere).
		end, ok := addChecked(now, a.antiSnipe)
		if !ok {
			panic("anti-snipe end-height overflow")
		}
		a.endHeight = end
		extended = true
	}

	chain.Emit("Bid",
		"auctionId", itoa(auctionID),
		"bidder", bidder.String(),
		"amount", itoa(amount),
		"endHeight", itoa(a.endHeight),
		"extended", boolStr(extended),
	)
}

// --- close (permissionless, like a sibling realm's valve) ---

// Close finalizes an auction whose end height has passed. Anyone may call it;
// no auction's terminal state may depend on a party acting. With a winner, the
// high bid is credited to the seller (fee split at the ledger) and the auction
// is Settled; with no bids it is Closed. The winner's escrowed payment moves
// from `locked` into the seller's claimable balance.
func Close(cur realm, auctionID int64) {
	assertNoSend()
	a := mustAuction(auctionID)
	if a.status != AuctionOpen {
		panic("auction is " + a.status)
	}
	if runtime.ChainHeight() < a.endHeight {
		panic("auction has not ended; ends at height " + itoa(a.endHeight))
	}
	if a.highBidder == "" {
		a.status = AuctionClosed
		chain.Emit("AuctionClosed", "auctionId", itoa(auctionID), "seller", a.seller.String())
		return
	}
	credited, fee := ledger.MustDeposit(a.seller.String(), a.highBid, a.feeBps)
	locked -= a.highBid
	a.status = AuctionSettled
	chain.Emit("AuctionSettled",
		"auctionId", itoa(auctionID),
		"seller", a.seller.String(),
		"winner", a.highBidder.String(),
		"price", itoa(a.highBid),
		"credited", itoa(credited),
		"fee", itoa(fee),
	)
}

// --- claims (pull: refunds and seller proceeds) ---

// Claim sends amount ugnot of the caller's claimable balance — outbid refunds
// and, if the caller is a seller of a settled auction, proceeds — to the
// caller.
func Claim(cur realm, amount int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire claimable balance to the caller.
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

// --- administration (two-step transfer, the house pattern) ---

func SetFeeBps(cur realm, bps int64) {
	assertNoSend()
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
	if bps < 0 || bps > MaxFeeBps {
		panic("fee must be 0.." + itoa(MaxFeeBps) + " bps")
	}
	feeBps = bps
	chain.Emit("FeeSet", "bps", itoa(bps))
}

func SetFeeRecipient(cur realm, recipient address) {
	assertNoSend()
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
	if !recipient.IsValid() {
		panic("invalid recipient")
	}
	feeRecipient = recipient
	chain.Emit("FeeRecipientSet", "to", recipient.String())
}

func WithdrawFees(cur realm) {
	assertNoSend()
	if cur.Previous().Address() != feeRecipient {
		panic("fee recipient only")
	}
	amount := ledger.WithdrawFees()
	if amount == 0 {
		panic("no fees accrued")
	}
	coinio.Payout(0, cur, feeRecipient, Denom, amount)
	chain.Emit("FeesWithdrawn", "to", feeRecipient.String(), "amount", itoa(amount))
}

// SweepDenom recovers out-of-band coins to the fee recipient. For the ledger
// denom the reserve is locked + Liabilities() — escrowed high bids, claimable
// refunds, seller proceeds and the fee pot are all structurally unreachable.
func SweepDenom(cur realm, denom string) {
	assertNoSend()
	if cur.Previous().Address() != feeRecipient {
		panic("fee recipient only")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = locked + ledger.Liabilities()
	}
	swept := coinio.Sweep(0, cur, feeRecipient, denom, reserve)
	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", itoa(swept)+denom)
}

func TransferAdmin(cur realm, successor address) {
	assertNoSend()
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
	if !successor.IsValid() {
		panic("invalid successor")
	}
	pendingAdmin = successor
	chain.Emit("AdminTransferStaged", "to", successor.String())
}

func AcceptAdmin(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	if pendingAdmin == "" || caller != pendingAdmin {
		panic("no admin transfer staged for caller")
	}
	admin = pendingAdmin
	pendingAdmin = ""
	chain.Emit("AdminTransferred", "to", caller.String())
}

// --- views (non-crossing: cross-realm readable) ---

// AuctionInfo returns an auction's terms and standing state. Lot text is a
// separate view ([Lot]) so this stays a numeric/address tuple.
func AuctionInfo(auctionID int64) (seller address, reserve, highBid, endHeight, antiSnipe, feeBps, createdHeight int64, highBidder address, status string) {
	a := mustAuction(auctionID)
	return a.seller, a.reserve, a.highBid, a.endHeight, a.antiSnipe, a.feeBps, a.createdHeight, a.highBidder, a.status
}

// Lot returns the auction's free-text lot description.
func Lot(auctionID int64) string { return mustAuction(auctionID).lot }

// MinNextBid is the smallest bid that would be accepted right now: the first
// bid's floor when there are no bids, else the standing high bid plus the
// minimum increment.
func MinNextBid(auctionID int64) int64 { return minNextBid(mustAuction(auctionID)) }

// HighBid is the standing high bid (0 if none).
func HighBid(auctionID int64) int64 { return mustAuction(auctionID).highBid }

// HighBidder is the standing high bidder ("" if none).
func HighBidder(auctionID int64) address { return mustAuction(auctionID).highBidder }

// Winner is the high bidder once the auction has Settled, else "".
func Winner(auctionID int64) address {
	a := mustAuction(auctionID)
	if a.status == AuctionSettled {
		return a.highBidder
	}
	return ""
}

// EndHeight is the current end height (which anti-snipe may have extended).
func EndHeight(auctionID int64) int64 { return mustAuction(auctionID).endHeight }

// Reserve is the auction's reserve price (0 if none).
func Reserve(auctionID int64) int64 { return mustAuction(auctionID).reserve }

// Status is the auction's status string.
func Status(auctionID int64) string { return mustAuction(auctionID).status }

// Seller is the auction's seller.
func Seller(auctionID int64) address { return mustAuction(auctionID).seller }

// IsOpen reports whether the auction is open and still before its end.
func IsOpen(auctionID int64) bool {
	a := mustAuction(auctionID)
	return a.status == AuctionOpen && runtime.ChainHeight() < a.endHeight
}

// IsCloseable reports whether Close would succeed right now.
func IsCloseable(auctionID int64) bool {
	a := mustAuction(auctionID)
	return a.status == AuctionOpen && runtime.ChainHeight() >= a.endHeight
}

// BlocksLeft is how many blocks until the end (0 once ended).
func BlocksLeft(auctionID int64) int64 {
	a := mustAuction(auctionID)
	left := a.endHeight - runtime.ChainHeight()
	if left < 0 {
		return 0
	}
	return left
}

func HasAuction(auctionID int64) bool { return auctions.Get(padID(auctionID)) != nil }

func AuctionsOf(seller address) int64 {
	v := sellerNum.Get(seller.String())
	if v == nil {
		return 0
	}
	return *v.(*int64)
}

func Admin() address              { return admin }
func PendingAdmin() address       { return pendingAdmin }
func FeeRecipient() address       { return feeRecipient }
func FeeBps() int64               { return feeBps }
func NumAuctions() int64          { return nextID }
func ClaimableOf(a address) int64 { return ledger.BalanceOf(a.String()) }
func FeesAccrued() int64          { return ledger.FeesAccrued() }
func Liabilities() int64          { return ledger.Liabilities() }
func Locked() int64               { return locked }
func Held() int64                 { return coinio.HeldAt(self, Denom) }
func Address() address            { return self }
func Height() int64               { return runtime.ChainHeight() }

// --- internals ---

// minNextBid is the smallest acceptable bid: the first-bid floor when no bid
// stands, else the high bid plus ceil(highBid·MinIncrementBps/10000). highBid
// is bounded by MaxBid, so the increment product cannot overflow.
func minNextBid(a *auction) int64 {
	if a.highBidder == "" {
		if a.reserve > MinBid {
			return a.reserve
		}
		return MinBid
	}
	return a.highBid + ceilDiv(a.highBid*MinIncrementBps, 10_000)
}

func mustAuction(id int64) *auction {
	v := auctions.Get(padID(id))
	if v == nil {
		panic("unknown auction " + itoa(id))
	}
	return v.(*auction)
}

func assertNoSend() {
	if !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

func counter(tree *avl.Tree, a address) *int64 {
	k := a.String()
	if v := tree.Get(k); v != nil {
		return v.(*int64)
	}
	n := int64(0)
	tree.Set(k, &n)
	return &n
}

// ceilDiv returns ceil(a/b) for b>0; a assumed non-negative.
func ceilDiv(a, b int64) int64 {
	if a <= 0 {
		return 0
	}
	return (a + b - 1) / b
}

func addChecked(a, b int64) (int64, bool) {
	s := a + b
	if (b > 0 && s < a) || (b < 0 && s > a) {
		return 0, false
	}
	return s, true
}

func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func hasPrefix(s, p string) bool { return len(s) >= len(p) && s[:len(p)] == p }

// --- Render ---

func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case hasPrefix(path, "auction/"):
		return renderAuction(path[len("auction/"):])
	default:
		return "unknown path; try \"\" or \"auction/<id>\"\n"
	}
}

func renderHome() string {
	out := "# auction — ascending auctions settled in ugnot\n\n"
	out += "Auctions: " + itoa(nextID) + " · escrowed high bids: " + itoa(locked) + Denom +
		" · claimable+fees held: " + itoa(ledger.Liabilities()) + Denom +
		" · fees accrued: " + itoa(ledger.FeesAccrued()) + Denom + "\n\n"
	out += "The realm escrows the standing high bid of every open auction; an outbid bid is refunded as a pull-claimable balance.\n\n"
	out += "| id | seller | lot | reserve | high bid | high bidder | status |\n|---|---|---|---|---|---|---|\n"
	shown := int64(0)
	for id := nextID - 1; id >= 0 && shown < RenderLimit; id-- {
		v := auctions.Get(padID(id))
		if v == nil {
			continue
		}
		a := v.(*auction)
		out += "| " + itoa(a.id) + " | " + sanitize.TableCell(a.seller.String()) + " | " +
			sanitize.TableCell(a.lot) + " | " + itoa(a.reserve) + Denom + " | " +
			itoa(a.highBid) + Denom + " | " + sanitize.TableCell(highBidderStr(a)) + " | " + a.status + " |\n"
		shown++
	}
	if nextID > shown {
		out += "\n(" + itoa(shown) + " most recent of " + itoa(nextID) + ")\n"
	}
	return out
}

func renderAuction(idStr string) string {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return "bad auction id\n"
	}
	v := auctions.Get(padID(id))
	if v == nil {
		return "unknown auction " + idStr + "\n"
	}
	a := v.(*auction)
	now := runtime.ChainHeight()
	out := "# auction " + itoa(a.id) + "\n\n"
	out += "- lot: " + sanitize.InlineText(a.lot) + "\n"
	out += "- seller: " + a.seller.String() + "\n"
	out += "- reserve: " + itoa(a.reserve) + Denom + " · fee: " + itoa(a.feeBps) + " bps\n"
	out += "- high bid: " + itoa(a.highBid) + Denom + " · high bidder: " + highBidderStr(a) + "\n"
	out += "- status: " + a.status + " · created at height " + itoa(a.createdHeight) +
		" · ends at height " + itoa(a.endHeight)
	if a.antiSnipe > 0 {
		out += " · anti-snipe " + itoa(a.antiSnipe) + " blocks"
	}
	out += "\n"
	if a.status == AuctionOpen {
		left := a.endHeight - now
		if left < 0 {
			left = 0
		}
		state := "accepting bids"
		if now >= a.endHeight {
			state = "ended — awaiting Close"
		}
		out += "- " + state + " · blocks left " + itoa(left) + " · minimum next bid " + itoa(minNextBid(a)) + Denom + "\n"
	}
	if a.status == AuctionSettled {
		out += "- winner: " + a.highBidder.String() + " at " + itoa(a.highBid) + Denom + "\n"
	}
	return out
}

func highBidderStr(a *auction) string {
	if a.highBidder == "" {
		return "(none)"
	}
	return a.highBidder.String()
}
