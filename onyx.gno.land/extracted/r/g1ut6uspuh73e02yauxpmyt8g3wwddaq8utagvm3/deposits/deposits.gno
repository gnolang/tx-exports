// Package deposits is a refundable security deposit with condition-gated,
// partially-forfeitable settlement.
//
// # The shape
//
// A HOLDER (landlord, service provider, equipment lessor) opens an agreement
// naming a DEPOSITOR, an exact amount, a term, and a FORFEIT CEILING — the most
// the holder may ever claim out of the deposit. The depositor reads all of it,
// including the named arbiter, and consents by FUNDING. At the end of the term
// the holder may file a claim up to the ceiling; the depositor may accept it,
// dispute it to the arbiter, or let it stand. Whatever is not awarded to the
// holder is refunded to the depositor.
//
// That makes this the first realm in the portfolio where ONE POT SPLITS
// PARTIALLY BETWEEN TWO RIVAL CLAIMANTS by a conditional rule, and the first
// where the depositor's own money is at risk of partial loss. `crowdfund` is
// all-or-nothing, `auction` is winner-takes, `loans` is principal-out /
// larger-back, `reimbursements` is approver-gated to a single claimant. See
// DISCOVERY.md for the §7 gate and the five candidates it killed.
//
// # Lifecycle
//
//	OpenAgreement  -> open       (nothing held; depositor has not consented)
//	Fund           -> funded     (depositor attaches the exact amount)
//	FileClaim      -> claimed    (holder, after term end, within the claim window)
//	Dispute        -> disputed   (depositor, within the dispute window)
//	ResolveDispute -> settled    (arbiter awards 0..claim to the holder)
//
// Five routes reach `settled`, and THREE OF THEM ARE PERMISSIONLESS, so no
// terminal state depends on a party acting:
//
//	AcceptClaim       depositor agrees           award = claim
//	SettleUndisputed  ANYONE, dispute window up  award = claim
//	ReleaseUnclaimed  ANYONE, claim window up    award = 0  (holder never claimed)
//	LapseDispute      ANYONE, arbiter silent     award = 0  (claim unsubstantiated)
//	Release           holder waives early        award = 0
//
// # Custody
//
// Coins are held by the realm from Fund until settlement, then become
// PULL-CLAIMABLE through `p/feeledger`. Nothing is ever pushed: a settlement
// credits balances and the parties `Claim` them, which removes the grief and
// reentrancy surface a push settlement would have.
//
// The conservation invariant carries one bucket more than the sibling realms:
//
//	Held == locked + contested + feeledger.Liabilities()
//
// `locked` and `contested` are DISJOINT — a disputed deposit moves out of one
// and into the other in the same transaction. The split exists because a
// contested deposit is the one balance whose destination is not yet decided by
// this realm's own rules; keeping it separate makes "what is the arbiter
// deciding over" a readable number rather than an inference.
//
// # The fee
//
// The protocol fee applies ONLY to the portion AWARDED to the holder. A refund
// to the depositor is returned in full at fee 0, matching `auction`'s rule that
// a refund is not a fee event. A fully-refunded deposit therefore costs the
// depositor nothing.
//
// # What the depositor is trusting, stated plainly
//
//   - The FORFEIT CEILING is the depositor's hard protection, and they consent
//     to it by funding. Nothing can take more than the ceiling.
//   - If NO ARBITER is named, an unaccepted claim STANDS once the dispute
//     window passes. That is a legitimate configuration — a deposit with a low
//     ceiling and no arbiter — and the depositor sees `Arbiter() == ""` before
//     funding.
//   - If an arbiter IS named, `LapseDispute` awards the contested amount to the
//     DEPOSITOR. A disappeared arbiter cannot strand funds, and the holder —
//     who chose the arbiter — bears the cost of that choice failing.
//   - Residual, not fixed here: a hostile depositor can dispute a legitimate
//     claim to delay settlement by one dispute window. The delay is bounded and
//     costs the depositor the same wait; it is disclosed rather than mitigated.
//   - The realm settles MONEY. Whether the damage was real is off-chain; this
//     realm binds the ceiling, the windows, and the arbiter's authority.
//
// # Scope
//
// Single-denom (ugnot), single depositor per agreement, flat ceiling. Graduated
// forfeiture over damage severity (`p/tiers`) is a deliberate v2 candidate, not
// an omission — see DISCOVERY.md §5.
package deposits

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
// to the portion AWARDED to the holder, never to a refund.
const MaxFeeBps = int64(1000)

// Agreement status values. Settled and Cancelled are terminal.
const (
	DepositOpen      = "open"      // created; the depositor has not funded
	DepositFunded    = "funded"    // funded; the term is running or the claim window is open
	DepositClaimed   = "claimed"   // the holder filed a claim; the depositor may accept or dispute
	DepositDisputed  = "disputed"  // the depositor disputed; the arbiter decides
	DepositSettled   = "settled"   // split credited; both parties pull
	DepositCancelled = "cancelled" // never funded; nothing moved
)

// Input bounds.
const (
	// MinDeposit is the dust floor; MaxDeposit keeps the split, the ceiling and
	// the fee far from int64 overflow. The depositor must ATTACH the deposit, so
	// the real ceiling is their balance.
	MinDeposit = int64(10_000)
	MaxDeposit = int64(1_000_000_000_000) // 1,000,000 GNOT

	// MinClaim is the dust floor for a forfeit ceiling and for any claim filed
	// against it. A ceiling below it would make FileClaim unsatisfiable.
	MinClaim = int64(1_000)

	// Term and window bounds, in blocks. The window floors keep a counterparty
	// from being given a deadline they cannot physically meet; the ceilings keep
	// height arithmetic far from overflow.
	MinTerm   = int64(10)
	MaxTerm   = int64(7_500_000)
	MinWindow = int64(10)
	MaxWindow = int64(7_500_000)

	// FundWindow is how long an unfunded agreement stays fundable. After it,
	// Fund refuses and CancelUnfunded is permissionless, so an abandoned offer
	// cannot occupy a holder's slot forever.
	FundWindow = int64(1_000_000)

	// MaxMemoLen and MaxReasonLen bound the stored free text.
	MaxMemoLen   = 200
	MaxReasonLen = 200

	// MaxAgreementsPerHolder bounds one holder's stored agreements. A terminal
	// agreement does NOT free the slot: a settled deposit is a permanent record
	// both parties and an auditor may need to read.
	MaxAgreementsPerHolder = 50

	// RenderLimit bounds every rendered list — an unbounded Render was YELLOW in
	// several prior audits in this portfolio.
	RenderLimit = 20
)

type agreement struct {
	id        int64
	holder    address
	depositor address
	arbiter   address // "" = none; a claim then cannot be disputed
	memo      string

	amount         int64 // the deposit; Fund must attach exactly this
	forfeitCeiling int64 // the most the holder may ever claim, in [MinClaim, amount]
	feeBps         int64 // snapshot at open; applied ONLY to the awarded portion
	termBlocks     int64
	claimWindow    int64
	disputeWindow  int64

	status        string
	createdHeight int64
	fundDeadline  int64 // createdHeight + FundWindow
	fundedHeight  int64 // 0 until funded
	termEnd       int64 // fundedHeight + termBlocks
	claimDeadline int64 // termEnd + claimWindow

	claimAmount     int64
	claimReason     string
	disputeDeadline int64 // claim height + disputeWindow
	disputeReason   string
	arbiterDeadline int64 // dispute height + disputeWindow

	award         int64 // credited to the holder at settlement
	settledHeight int64
}

var (
	admin        address
	pendingAdmin address
	feeRecipient address
	feeBps       int64 // snapshotted into NEW agreements

	self      address
	nextID    int64
	locked    int64 // Σ amounts of funded/claimed agreements (destination not yet decided by a party)
	contested int64 // Σ amounts of DISPUTED agreements (an arbiter is deciding)

	agreements = avl.NewTree() // padID(id)       -> *agreement
	holderNum  = avl.NewTree() // holder.String() -> *int64, stored agreements
	ledger     = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// --- holder side ---

// OpenAgreement offers a deposit agreement. The caller becomes the holder and
// names the `depositor`, the exact `amount` they must attach, the `termBlocks`
// the deposit is held for, the `claimWindow` the holder has to file a claim
// after the term ends, the `disputeWindow` the depositor has to dispute one (and
// the arbiter then has to rule), and the `forfeitCeiling` — the most the holder
// may ever claim, in [MinClaim, amount]. `arbiter` may be the zero address, in
// which case a claim cannot be disputed; it may not be either party. Nothing is
// held until the depositor Funds, which is how they consent to all of it. The
// current protocol fee is snapshotted in. Returns the id.
func OpenAgreement(cur realm, depositor address, amount, forfeitCeiling, termBlocks, claimWindow, disputeWindow int64, arbiter address, memo string) int64 {
	assertNoSend()
	holder := cur.Previous().Address()
	if !depositor.IsValid() {
		panic("invalid depositor address")
	}
	if depositor == holder {
		panic("holder and depositor must differ")
	}
	if arbiter != "" {
		if !arbiter.IsValid() {
			panic("invalid arbiter address")
		}
		if arbiter == holder || arbiter == depositor {
			panic("the arbiter may not be either party")
		}
	}
	if amount < MinDeposit || amount > MaxDeposit {
		panic("deposit must be " + itoa(MinDeposit) + ".." + itoa(MaxDeposit) + Denom)
	}
	if forfeitCeiling < MinClaim || forfeitCeiling > amount {
		panic("forfeit ceiling must be " + itoa(MinClaim) + ".." + itoa(amount) + Denom)
	}
	if termBlocks < MinTerm || termBlocks > MaxTerm {
		panic("term must be " + itoa(MinTerm) + ".." + itoa(MaxTerm) + " blocks")
	}
	if claimWindow < MinWindow || claimWindow > MaxWindow {
		panic("claim window must be " + itoa(MinWindow) + ".." + itoa(MaxWindow) + " blocks")
	}
	if disputeWindow < MinWindow || disputeWindow > MaxWindow {
		panic("dispute window must be " + itoa(MinWindow) + ".." + itoa(MaxWindow) + " blocks")
	}
	if len(memo) > MaxMemoLen {
		panic("memo must be at most " + itoa(MaxMemoLen) + " bytes")
	}
	n := counter(holderNum, holder)
	if *n >= MaxAgreementsPerHolder {
		panic("holder has reached " + itoa(MaxAgreementsPerHolder) + " stored agreements")
	}

	now := runtime.ChainHeight()
	deadline, ok := addChecked(now, FundWindow)
	if !ok {
		panic("fund-deadline height overflow")
	}
	id := nextID
	nextID++
	d := &agreement{
		id:             id,
		holder:         holder,
		depositor:      depositor,
		arbiter:        arbiter,
		memo:           memo,
		amount:         amount,
		forfeitCeiling: forfeitCeiling,
		feeBps:         feeBps,
		termBlocks:     termBlocks,
		claimWindow:    claimWindow,
		disputeWindow:  disputeWindow,
		status:         DepositOpen,
		createdHeight:  now,
		fundDeadline:   deadline,
	}
	agreements.Set(padID(id), d)
	*n++

	chain.Emit("AgreementOpened",
		"id", itoa(id),
		"holder", holder.String(),
		"depositor", depositor.String(),
		"arbiter", arbiter.String(),
		"amount", itoa(amount),
		"forfeitCeiling", itoa(forfeitCeiling),
		"fundDeadline", itoa(deadline),
	)
	return id
}

// FileClaim claims `amount` of the deposit against the ceiling. Holder only,
// only once, only after the term has ended and before the claim window closes.
// `amount` must be in [MinClaim, forfeitCeiling]. The depositor may then accept
// it, dispute it to the arbiter, or let it stand.
func FileClaim(cur realm, id, amount int64, reason string) {
	assertNoSend()
	d := mustAgreement(id)
	if cur.Previous().Address() != d.holder {
		panic("holder only")
	}
	if d.status != DepositFunded {
		panic("agreement is " + d.status)
	}
	now := runtime.ChainHeight()
	if now < d.termEnd {
		panic("the term has not ended; it ends at height " + itoa(d.termEnd))
	}
	if now >= d.claimDeadline {
		panic("the claim window closed at height " + itoa(d.claimDeadline))
	}
	if amount < MinClaim || amount > d.forfeitCeiling {
		panic("claim must be " + itoa(MinClaim) + ".." + itoa(d.forfeitCeiling) + Denom)
	}
	if len(reason) == 0 || len(reason) > MaxReasonLen {
		panic("reason must be 1.." + itoa(MaxReasonLen) + " bytes")
	}
	// Checked like every other deadline, though the window bounds put overflow
	// out of reach.
	until, ok := addChecked(now, d.disputeWindow)
	if !ok {
		panic("dispute-deadline height overflow")
	}
	d.claimAmount = amount
	d.claimReason = reason
	d.disputeDeadline = until
	d.status = DepositClaimed

	chain.Emit("ClaimFiled",
		"id", itoa(id),
		"holder", d.holder.String(),
		"amount", itoa(amount),
		"disputeDeadline", itoa(until),
	)
}

// Release returns the whole deposit to the depositor early. Holder only, while
// the agreement is funded and unclaimed. It is the holder waiving the claim they
// have not yet filed — the one route to settlement that needs no clock.
func Release(cur realm, id int64) {
	assertNoSend()
	d := mustAgreement(id)
	if cur.Previous().Address() != d.holder {
		panic("holder only")
	}
	if d.status != DepositFunded {
		panic("agreement is " + d.status)
	}
	settle(d, 0, false)
	chain.Emit("Settled",
		"id", itoa(id),
		"route", "release",
		"award", "0",
		"refund", itoa(d.amount),
	)
}

// --- depositor side ---

// Fund attaches the exact deposit and starts the term. The named depositor only;
// the attached amount must equal the agreement's amount exactly, and the fund
// deadline must not have passed. Funding IS the depositor's consent to the
// ceiling, the windows and the arbiter, all of which were readable beforehand.
func Fund(cur realm, id int64) {
	from, amount := coinio.Receive(0, cur, Denom)
	d := mustAgreement(id)
	if d.status != DepositOpen {
		panic("agreement is " + d.status)
	}
	if from != d.depositor {
		panic("only the named depositor may fund this agreement")
	}
	now := runtime.ChainHeight()
	if now >= d.fundDeadline {
		panic("the fund window closed at height " + itoa(d.fundDeadline))
	}
	if amount != d.amount {
		panic("attach exactly " + itoa(d.amount) + Denom + "; got " + itoa(amount))
	}
	termEnd, ok := addChecked(now, d.termBlocks)
	if !ok {
		panic("term-end height overflow")
	}
	claimDeadline, ok := addChecked(termEnd, d.claimWindow)
	if !ok {
		panic("claim-deadline height overflow")
	}
	// coinio already received `amount`, so Held rose by amount; locking it keeps
	// Held == locked + contested + Liabilities exactly.
	locked += amount
	d.fundedHeight = now
	d.termEnd = termEnd
	d.claimDeadline = claimDeadline
	d.status = DepositFunded

	chain.Emit("Funded",
		"id", itoa(id),
		"depositor", from.String(),
		"amount", itoa(amount),
		"termEnd", itoa(termEnd),
		"claimDeadline", itoa(claimDeadline),
	)
}

// AcceptClaim settles at the claimed amount. Depositor only, while a claim
// stands. Accepting early is allowed — the dispute window is a deadline for
// disputing, not a waiting period.
func AcceptClaim(cur realm, id int64) {
	assertNoSend()
	d := mustAgreement(id)
	if cur.Previous().Address() != d.depositor {
		panic("depositor only")
	}
	if d.status != DepositClaimed {
		panic("agreement is " + d.status)
	}
	award := d.claimAmount
	credited, fee := settle(d, award, false)
	chain.Emit("Settled",
		"id", itoa(id),
		"route", "accept",
		"award", itoa(award),
		"credited", itoa(credited),
		"fee", itoa(fee),
		"refund", itoa(d.amount-award),
	)
}

// Dispute sends a standing claim to the arbiter. Depositor only, before the
// dispute deadline, and only if an arbiter was named — with no arbiter there is
// nobody to decide, and the depositor saw that before funding. The deposit moves
// from `locked` into `contested`; no coins move.
func Dispute(cur realm, id int64, reason string) {
	assertNoSend()
	d := mustAgreement(id)
	if cur.Previous().Address() != d.depositor {
		panic("depositor only")
	}
	if d.status != DepositClaimed {
		panic("agreement is " + d.status)
	}
	if d.arbiter == "" {
		panic("no arbiter was named; a claim cannot be disputed")
	}
	now := runtime.ChainHeight()
	if now >= d.disputeDeadline {
		panic("the dispute window closed at height " + itoa(d.disputeDeadline))
	}
	if len(reason) == 0 || len(reason) > MaxReasonLen {
		panic("reason must be 1.." + itoa(MaxReasonLen) + " bytes")
	}
	until, ok := addChecked(now, d.disputeWindow)
	if !ok {
		panic("arbiter-deadline height overflow")
	}
	locked -= d.amount
	contested += d.amount
	d.disputeReason = reason
	d.arbiterDeadline = until
	d.status = DepositDisputed

	chain.Emit("Disputed",
		"id", itoa(id),
		"depositor", d.depositor.String(),
		"arbiter", d.arbiter.String(),
		"claim", itoa(d.claimAmount),
		"arbiterDeadline", itoa(until),
	)
}

// --- arbiter ---

// ResolveDispute rules on a disputed claim. Arbiter only. `awardToHolder` is in
// [0, the claimed amount] — the arbiter may reduce a claim or deny it outright
// but never award more than was claimed, which is itself capped by the ceiling
// the depositor consented to. No deadline is enforced here: a late ruling is
// better than a stranded deposit, and `LapseDispute` is the race that bounds it.
func ResolveDispute(cur realm, id, awardToHolder int64) {
	assertNoSend()
	d := mustAgreement(id)
	if cur.Previous().Address() != d.arbiter {
		panic("arbiter only")
	}
	if d.status != DepositDisputed {
		panic("agreement is " + d.status)
	}
	if awardToHolder < 0 || awardToHolder > d.claimAmount {
		panic("award must be 0.." + itoa(d.claimAmount) + Denom)
	}
	credited, fee := settle(d, awardToHolder, true)
	chain.Emit("Settled",
		"id", itoa(id),
		"route", "arbiter",
		"award", itoa(awardToHolder),
		"credited", itoa(credited),
		"fee", itoa(fee),
		"refund", itoa(d.amount-awardToHolder),
	)
}

// --- permissionless valves: no terminal state depends on a party acting ---

// ReleaseUnclaimed refunds the whole deposit because the holder never filed a
// claim before the window closed. Anyone may call it.
func ReleaseUnclaimed(cur realm, id int64) {
	assertNoSend()
	d := mustAgreement(id)
	if d.status != DepositFunded {
		panic("agreement is " + d.status)
	}
	if runtime.ChainHeight() < d.claimDeadline {
		panic("the claim window is open until height " + itoa(d.claimDeadline))
	}
	settle(d, 0, false)
	chain.Emit("Settled",
		"id", itoa(id),
		"route", "unclaimed",
		"award", "0",
		"refund", itoa(d.amount),
	)
}

// SettleUndisputed settles at the claimed amount because the depositor neither
// accepted nor disputed before the dispute window closed. Anyone may call it.
func SettleUndisputed(cur realm, id int64) {
	assertNoSend()
	d := mustAgreement(id)
	if d.status != DepositClaimed {
		panic("agreement is " + d.status)
	}
	if runtime.ChainHeight() < d.disputeDeadline {
		panic("the dispute window is open until height " + itoa(d.disputeDeadline))
	}
	award := d.claimAmount
	credited, fee := settle(d, award, false)
	chain.Emit("Settled",
		"id", itoa(id),
		"route", "undisputed",
		"award", itoa(award),
		"credited", itoa(credited),
		"fee", itoa(fee),
		"refund", itoa(d.amount-award),
	)
}

// LapseDispute refunds the whole deposit because the arbiter did not rule before
// their deadline. Anyone may call it. The award is 0, not the claim: an
// unsubstantiated claim fails. The holder chose the arbiter and bears the cost
// of that choice failing — which is also why a disappeared arbiter can never
// strand a deposit.
func LapseDispute(cur realm, id int64) {
	assertNoSend()
	d := mustAgreement(id)
	if d.status != DepositDisputed {
		panic("agreement is " + d.status)
	}
	if runtime.ChainHeight() < d.arbiterDeadline {
		panic("the arbiter has until height " + itoa(d.arbiterDeadline))
	}
	settle(d, 0, true)
	chain.Emit("Settled",
		"id", itoa(id),
		"route", "lapsed",
		"award", "0",
		"refund", itoa(d.amount),
	)
}

// CancelUnfunded abandons an agreement the depositor never funded. Either party
// may cancel at any time — refusing to fund is the depositor's right and
// withdrawing the offer is the holder's — and ANYONE may cancel once the fund
// deadline has passed, so a dead offer cannot hold a slot forever. No coins have
// ever been held, so nothing moves.
func CancelUnfunded(cur realm, id int64) {
	assertNoSend()
	d := mustAgreement(id)
	if d.status != DepositOpen {
		panic("agreement is " + d.status)
	}
	caller := cur.Previous().Address()
	party := caller == d.holder || caller == d.depositor
	if !party && runtime.ChainHeight() < d.fundDeadline {
		panic("only the holder or the depositor may cancel before height " + itoa(d.fundDeadline))
	}
	d.status = DepositCancelled
	chain.Emit("Cancelled", "id", itoa(id), "by", caller.String())
}

// --- claims (pull: refunds, awards and fees) ---

// Claim sends amount ugnot of the caller's claimable balance — refunds and
// awards from settled agreements — to the caller.
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

// SetFeeRecipient names the address that may withdraw the accrued fee pot.
//
// It deliberately does NOT enforce disjointness from agreement parties, in
// contrast to OpenAgreement, which refuses an arbiter equal to either party.
// The two rules are not comparable, and the asymmetry is the point:
//
//   - The arbiter rule is per-agreement and checked at the moment the
//     agreement is created, so it is an invariant of that agreement for life.
//   - The fee recipient is one global over an unbounded, growing set of
//     agreements. A check here could only test a snapshot, and the very next
//     OpenAgreement could name the sitting recipient as holder or depositor.
//     A guard that any later transaction can walk through is worse than no
//     guard: it reads as an invariant and is not one.
//
// Nothing is at stake in the overlap, which is why the honest answer is a
// documented omission rather than a decorative check. The fee is derived only
// from the holder's award inside ledger.MustDeposit, never from the refund, so
// a recipient who is also a holder collects the same coins by two routes
// instead of more coins. Solvency is unaffected in either direction:
// feeledger accounts user credit and the fee pot as separate buckets, both are
// inside ledger.Liabilities(), and SweepDenom's reserve is
// locked + contested + ledger.Liabilities() — so an overlapping recipient
// cannot make the swept surplus overstate what the realm is free to release.
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
// denom the reserve is locked + contested + Liabilities() — held deposits,
// contested deposits, claimable refunds, awards and the fee pot are all
// structurally unreachable.
func SweepDenom(cur realm, denom string) {
	assertNoSend()
	if cur.Previous().Address() != feeRecipient {
		panic("fee recipient only")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = locked + contested + ledger.Liabilities()
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

// AgreementInfo returns the whole agreement in one read, so a depositor
// deciding whether to fund does not have to compose nine calls.
func AgreementInfo(id int64) (holder, depositor, arbiter address, amount, forfeitCeiling, feeBps, termEnd, claimDeadline, disputeDeadline, arbiterDeadline, claimAmount, award int64, status string) {
	d := mustAgreement(id)
	return d.holder, d.depositor, d.arbiter, d.amount, d.forfeitCeiling, d.feeBps,
		d.termEnd, d.claimDeadline, d.disputeDeadline, d.arbiterDeadline,
		d.claimAmount, d.award, d.status
}

func Memo(id int64) string          { return mustAgreement(id).memo }
func ClaimReason(id int64) string   { return mustAgreement(id).claimReason }
func DisputeReason(id int64) string { return mustAgreement(id).disputeReason }

func Holder(id int64) address       { return mustAgreement(id).holder }
func Depositor(id int64) address    { return mustAgreement(id).depositor }
func Arbiter(id int64) address      { return mustAgreement(id).arbiter }
func Amount(id int64) int64         { return mustAgreement(id).amount }
func ForfeitCeiling(id int64) int64 { return mustAgreement(id).forfeitCeiling }
func FeeBpsOf(id int64) int64       { return mustAgreement(id).feeBps }
func Status(id int64) string        { return mustAgreement(id).status }
func ClaimAmount(id int64) int64    { return mustAgreement(id).claimAmount }
func Award(id int64) int64          { return mustAgreement(id).award }
func TermEnd(id int64) int64        { return mustAgreement(id).termEnd }
func ClaimDeadline(id int64) int64  { return mustAgreement(id).claimDeadline }
func FundDeadline(id int64) int64   { return mustAgreement(id).fundDeadline }

// DisputeDeadlineOf is the last height at which the depositor may Dispute a
// standing claim; ArbiterDeadlineOf is the last height at which the arbiter's
// ruling pre-empts LapseDispute. Both are 0 until the relevant stage is live.
func DisputeDeadlineOf(id int64) int64 { return mustAgreement(id).disputeDeadline }
func ArbiterDeadlineOf(id int64) int64 { return mustAgreement(id).arbiterDeadline }

func CreatedHeight(id int64) int64 { return mustAgreement(id).createdHeight }
func FundedHeight(id int64) int64  { return mustAgreement(id).fundedHeight }
func SettledHeight(id int64) int64 { return mustAgreement(id).settledHeight }

// Refund is the amount the depositor gets back, known only once settled.
func Refund(id int64) int64 {
	d := mustAgreement(id)
	if d.status != DepositSettled {
		panic("agreement is " + d.status + "; the split is not decided")
	}
	return d.amount - d.award
}

// MaxClaimable is the most the holder could still take out of this agreement.
// It is the ceiling while the deposit is funded, the filed claim once one
// stands, and 0 once the agreement is terminal.
func MaxClaimable(id int64) int64 {
	d := mustAgreement(id)
	switch d.status {
	case DepositOpen, DepositFunded:
		return d.forfeitCeiling
	case DepositClaimed, DepositDisputed:
		return d.claimAmount
	default:
		return 0
	}
}

func IsSettled(id int64) bool { return mustAgreement(id).status == DepositSettled }

// IsClaimable reports whether FileClaim would be accepted at this height.
func IsClaimable(id int64) bool {
	d := mustAgreement(id)
	now := runtime.ChainHeight()
	return d.status == DepositFunded && now >= d.termEnd && now < d.claimDeadline
}

// IsDisputable reports whether Dispute would be accepted at this height.
func IsDisputable(id int64) bool {
	d := mustAgreement(id)
	return d.status == DepositClaimed && d.arbiter != "" && runtime.ChainHeight() < d.disputeDeadline
}

// PendingValve names the permissionless call this agreement is ready for, or ""
// when none is. It is the one view a keeper needs.
func PendingValve(id int64) string {
	d := mustAgreement(id)
	now := runtime.ChainHeight()
	switch d.status {
	case DepositOpen:
		if now >= d.fundDeadline {
			return "CancelUnfunded"
		}
	case DepositFunded:
		if now >= d.claimDeadline {
			return "ReleaseUnclaimed"
		}
	case DepositClaimed:
		if now >= d.disputeDeadline {
			return "SettleUndisputed"
		}
	case DepositDisputed:
		if now >= d.arbiterDeadline {
			return "LapseDispute"
		}
	}
	return ""
}

func HasAgreement(id int64) bool { return agreements.Get(padID(id)) != nil }

func AgreementsOf(holder address) int64 {
	v := holderNum.Get(holder.String())
	if v == nil {
		return 0
	}
	return *v.(*int64)
}

func Admin() address              { return admin }
func PendingAdmin() address       { return pendingAdmin }
func FeeRecipient() address       { return feeRecipient }
func FeeBps() int64               { return feeBps }
func NumAgreements() int64        { return nextID }
func ClaimableOf(a address) int64 { return ledger.BalanceOf(a.String()) }
func FeesAccrued() int64          { return ledger.FeesAccrued() }
func Liabilities() int64          { return ledger.Liabilities() }
func Locked() int64               { return locked }
func Contested() int64            { return contested }
func Held() int64                 { return coinio.HeldAt(self, Denom) }
func Address() address            { return self }
func Height() int64               { return runtime.ChainHeight() }

// --- internals ---

// settle credits the split and moves the deposit out of its custody bucket. The
// caller has already established the route's authority and timing; `award` is in
// [0, amount] and `fromContested` says which bucket the deposit sits in.
//
// Conservation, in delta form: Held is unchanged; locked OR contested falls by
// amount; Liabilities rises by award + (amount-award) == amount. So
// Held == locked + contested + Liabilities is preserved exactly.
//
// The fee is charged ONLY on the award. The refund is deposited at fee 0, so a
// fully-refunded deposit returns to the depositor in full.
func settle(d *agreement, award int64, fromContested bool) (credited, fee int64) {
	if award < 0 || award > d.amount {
		// Unreachable: every route bounds the award by claimAmount, itself
		// bounded by forfeitCeiling <= amount. Kept as a solvency backstop.
		panic("award out of range")
	}
	if fromContested {
		contested -= d.amount
	} else {
		locked -= d.amount
	}
	if award > 0 {
		credited, fee = ledger.MustDeposit(d.holder.String(), award, d.feeBps)
	}
	if refund := d.amount - award; refund > 0 {
		ledger.MustDeposit(d.depositor.String(), refund, 0)
	}
	d.award = award
	d.settledHeight = runtime.ChainHeight()
	d.status = DepositSettled
	return credited, fee
}

func mustAgreement(id int64) *agreement {
	v := agreements.Get(padID(id))
	if v == nil {
		panic("unknown agreement " + itoa(id))
	}
	return v.(*agreement)
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

func addrStr(a address) string {
	if a == "" {
		return "(none)"
	}
	return a.String()
}

func hasPrefix(s, p string) bool { return len(s) >= len(p) && s[:len(p)] == p }

// --- Render ---

func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case hasPrefix(path, "agreement/"):
		return renderAgreement(path[len("agreement/"):])
	default:
		return "unknown path; try \"\" or \"agreement/<id>\"\n"
	}
}

func renderHome() string {
	out := "# deposits — refundable security deposits with condition-gated forfeiture\n\n"
	out += "Agreements: " + itoa(nextID) + " · held deposits: " + itoa(locked) + Denom +
		" · contested: " + itoa(contested) + Denom +
		" · claimable+fees: " + itoa(ledger.Liabilities()) + Denom +
		" · fees accrued: " + itoa(ledger.FeesAccrued()) + Denom + "\n\n"
	out += "A holder offers an agreement with a **forfeit ceiling**; the depositor consents by funding it. " +
		"At the end of the term the holder may claim up to the ceiling, the depositor may accept or dispute, " +
		"and whatever is not awarded is refunded. Settlements are pull-claimable, never pushed.\n\n"
	out += "| id | holder | depositor | amount | ceiling | claim | status |\n|---|---|---|---|---|---|---|\n"
	shown := int64(0)
	for id := nextID - 1; id >= 0 && shown < RenderLimit; id-- {
		v := agreements.Get(padID(id))
		if v == nil {
			continue
		}
		d := v.(*agreement)
		out += "| " + itoa(d.id) + " | " + sanitize.TableCell(d.holder.String()) + " | " +
			sanitize.TableCell(d.depositor.String()) + " | " + itoa(d.amount) + Denom + " | " +
			itoa(d.forfeitCeiling) + Denom + " | " + itoa(d.claimAmount) + Denom + " | " +
			d.status + " |\n"
		shown++
	}
	if nextID > shown {
		out += "\n(" + itoa(shown) + " most recent of " + itoa(nextID) + ")\n"
	}
	return out
}

func renderAgreement(idStr string) string {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return "bad agreement id\n"
	}
	v := agreements.Get(padID(id))
	if v == nil {
		return "unknown agreement " + idStr + "\n"
	}
	d := v.(*agreement)
	now := runtime.ChainHeight()
	// These four slots carry an own-package status constant and bech32 addresses,
	// so sanitize.InlineText is the IDENTITY on every reachable input and this is
	// not an injection repair. It is here because renderHome wraps the same two
	// addresses (as sanitize.TableCell, the table-context analogue) and an
	// asymmetry between two renderers over one data set is how the wrapped side
	// gets deleted later to "match". The wrap is what survives a refactor that
	// puts non-constant data in a slot; tools/test_deposits_sabotage.sh footer
	// non-case (e) records that no fixture can distinguish it today.
	out := "# agreement " + itoa(d.id) + " — " + sanitize.InlineText(d.status) + "\n\n"
	out += "- holder: " + sanitize.InlineText(d.holder.String()) + "\n"
	out += "- depositor: " + sanitize.InlineText(d.depositor.String()) + "\n"
	out += "- arbiter: " + sanitize.InlineText(addrStr(d.arbiter))
	if d.arbiter == "" {
		out += " — **a claim cannot be disputed**"
	}
	out += "\n"
	if d.memo != "" {
		out += "- memo: " + sanitize.InlineText(d.memo) + "\n"
	}
	out += "- deposit: " + itoa(d.amount) + Denom + " · forfeit ceiling: " + itoa(d.forfeitCeiling) +
		Denom + " · fee on the award: " + itoa(d.feeBps) + " bps\n"
	out += "- term " + itoa(d.termBlocks) + " blocks · claim window " + itoa(d.claimWindow) +
		" · dispute window " + itoa(d.disputeWindow) + " · opened at height " + itoa(d.createdHeight) + "\n"

	switch d.status {
	case DepositOpen:
		out += "- awaiting funding by the depositor until height " + itoa(d.fundDeadline) + "\n"
	case DepositFunded:
		if now < d.termEnd {
			out += "- term running · ends at height " + itoa(d.termEnd) +
				" (" + itoa(d.termEnd-now) + " blocks)\n"
		} else if now < d.claimDeadline {
			out += "- claim window OPEN until height " + itoa(d.claimDeadline) +
				" · the holder may claim up to " + itoa(d.forfeitCeiling) + Denom + "\n"
		} else {
			out += "- no claim was filed · anyone may call ReleaseUnclaimed for a full refund\n"
		}
	case DepositClaimed:
		out += "- claim: " + itoa(d.claimAmount) + Denom + " — " + sanitize.InlineText(d.claimReason) + "\n"
		if now < d.disputeDeadline {
			out += "- the depositor may accept or dispute until height " + itoa(d.disputeDeadline) + "\n"
		} else {
			out += "- dispute window closed · anyone may call SettleUndisputed\n"
		}
	case DepositDisputed:
		out += "- claim: " + itoa(d.claimAmount) + Denom + " — " + sanitize.InlineText(d.claimReason) + "\n"
		out += "- disputed: " + sanitize.InlineText(d.disputeReason) + "\n"
		if now < d.arbiterDeadline {
			out += "- the arbiter rules by height " + itoa(d.arbiterDeadline) + "\n"
		} else {
			out += "- the arbiter did not rule · anyone may call LapseDispute for a full refund\n"
		}
	case DepositSettled:
		out += "- settled at height " + itoa(d.settledHeight) + " · awarded to the holder " +
			itoa(d.award) + Denom + " · refunded to the depositor " + itoa(d.amount-d.award) + Denom + "\n"
		out += "- both sides are pull-claimable with Claim / ClaimAll\n"
	case DepositCancelled:
		out += "- cancelled before funding · no coins were ever held\n"
	}
	return out
}
