// Package subscriptions is a multi-provider subscription hub: providers
// publish plans priced per billing period; subscribers pay per period,
// with deterministic renewal, grace, expiration and cancellation rules;
// other realms and off-chain services gate access on Entitled /
// EntitledFor, which is the integration surface this realm exists to
// provide.
//
// THE BILLING MODEL, COMPLETELY:
//
//	Subscribe (payable, exact price)  : creates the subscription, pays
//	                                    period 1. paidThrough = height
//	                                    + periodBlocks.
//	Renew (payable, exact price)      : extends paidThrough by exactly
//	                                    one periodBlocks, FROM
//	                                    paidThrough — never from the
//	                                    current height — so period
//	                                    boundaries are fixed at
//	                                    Subscribe time and never drift.
//	Entitlement                       : height < paidThrough. Nothing
//	                                    else. Status does not enter
//	                                    into it: a cancelled
//	                                    subscription stays entitled to
//	                                    what it already paid for.
//	Renewal window                    : a renewal is accepted iff BOTH
//	                    paidThrough - height <= periodBlocks   (early bound)
//	                    height < paidThrough + periodBlocks    (late bound)
//	                                    The early bound caps prepayment
//	                                    at one full unstarted period —
//	                                    a second Renew straight after a
//	                                    first is refused, which is what
//	                                    makes an accidental duplicate
//	                                    payment structurally impossible
//	                                    rather than merely unlikely.
//	                                    The late bound is the grace
//	                                    window: renewing after lapse
//	                                    extends from paidThrough, so it
//	                                    back-pays the lapsed span to
//	                                    keep the original schedule and
//	                                    buys paidThrough + periodBlocks
//	                                    - height further blocks — always
//	                                    at least one, because the bound
//	                                    is exclusive (audit finding Y2).
//	                                    A lapsed subscriber who prefers
//	                                    a fresh full period may Cancel
//	                                    and Subscribe again at the same
//	                                    total price; Subscribe's refusal
//	                                    message states both options.
//	Expire (permissionless valve)     : once height >= paidThrough +
//	                                    periodBlocks, anyone may mark
//	                                    the subscription Expired. No
//	                                    funds move — every payment
//	                                    settled when it was made. The
//	                                    valve exists so the
//	                                    plan|subscriber slot frees
//	                                    without depending on either
//	                                    party, and Subscribe itself
//	                                    collapses an expired incumbent,
//	                                    so a fresh start never depends
//	                                    on housekeeping having run. The
//	                                    renewable and expirable height
//	                                    sets partition exactly: no
//	                                    height is in both or neither.
//	Cancel (subscriber only)          : Active -> Cancelled. Terminal.
//	                                    No refund — payments settle to
//	                                    the provider at payment time,
//	                                    and what was bought (entitlement
//	                                    through paidThrough) stays
//	                                    bought. What cancellation ends
//	                                    is the OBLIGATION: a Cancelled
//	                                    subscription can never be
//	                                    renewed, by the subscriber or
//	                                    anyone else.
//	RetirePlan (provider only)        : no new Subscribes, no renewals.
//	                                    Existing entitlements run to
//	                                    paidThrough untouched. Refusing
//	                                    renewals on a retired plan is
//	                                    subscriber protection: nobody
//	                                    can keep paying for a service
//	                                    whose provider announced its
//	                                    end.
//
// The obligation is therefore explicit on chain at every moment: a
// subscription owes nothing (there is no pull payment and no debt — a
// lapse simply ends entitlement), and the realm owes the subscriber
// exactly `paidThrough - height` blocks of entitlement, queryable by
// anyone via PaidThrough / Entitled / EntitledFor.
//
// WHO PAYS WHOM. Payments settle immediately: price - fee is credited
// to the provider's claimable balance, fee to the protocol pot, both
// inside the same feeledger the sibling realms use. There is no escrow:
// H == U + F at all times (plus out-of-band surplus, recoverable by
// SweepDenom above the Liabilities reserve). The renewal caller must be
// the subscriber — a third party cannot extend someone else's
// subscription, which closes both a consent problem (an unwanted gift
// re-arms a lapsing obligation) and a griefing edge (spending pennies
// to keep a victim's slot occupied).
//
// FEES follow the house pattern exactly: a compile-time MaxFeeBps
// ceiling, the current fee snapshotted into the PLAN at CreatePlan
// (provider consents via its own maxFeeBps argument), copied into the
// subscription at Subscribe, and charged at every payment from the
// PROVIDER's side. A later SetFeeBps touches only plans created
// afterwards; no existing plan or subscription can have its fee moved
// by anyone.
//
// REALM-CALLER CAVEAT, inherited from the siblings verbatim: coinio's
// receipt guard admits only EOA payers, so subscribers are EOAs;
// assertNoSend reads the ORIGIN envelope, so every non-payable function
// refuses any transaction that attached coins anywhere. Providers may
// be EOAs or realms, but a realm provider must expose its own crossing
// path to Claim, or what it earns is stranded (see RegisterService's
// caveat in service_market — the same three obligations apply).
package subscriptions

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

// Plan status values.
const (
	PlanActive  = "active"
	PlanRetired = "retired"
)

// Subscription status values. Cancelled and Expired are terminal.
const (
	SubActive    = "active"
	SubCancelled = "cancelled"
	SubExpired   = "expired"
)

// Input bounds.
const (
	MaxTitleLen = 80
	MaxDescLen  = 2000
	MinPrice    = int64(1)

	// MinPeriodBlocks/MaxPeriodBlocks bound a plan's billing period:
	// ~40 seconds to ~1 year at pearl's observed ~4.2s blocks. The
	// floor keeps a hostile plan from turning renewal into a
	// per-block treadmill; the ceiling keeps paidThrough arithmetic
	// far from overflow even at maximum prepayment.
	MinPeriodBlocks = int64(10)
	MaxPeriodBlocks = int64(7500000)

	// MaxPlansPerProvider bounds catalog monopolization by a single
	// address — the finding that was RED in permission_registry and
	// service_registry, carried from the start here.
	MaxPlansPerProvider = 20

	// MaxSubsPerSubscriber bounds one account's open-subscription
	// state. Terminal subscriptions free their slot.
	MaxSubsPerSubscriber = 100

	// RenderLimit bounds every rendered list — an unbounded Render
	// was YELLOW in three prior audits.
	RenderLimit = 20
)

type plan struct {
	id           int64
	provider     address
	title        string
	description  string
	price        int64
	periodBlocks int64
	feeBps       int64 // snapshotted at creation, charged at every payment
	status       string
	subs         int64 // lifetime count, never decremented
}

type sub struct {
	id           int64
	planID       int64
	subscriber   address
	provider     address // copied at Subscribe; never re-read from the plan
	price        int64   // copied at Subscribe; a plan is immutable anyway
	periodBlocks int64   // copied at Subscribe
	feeBps       int64   // copied at Subscribe from the plan's snapshot
	status       string
	paidThrough  int64 // absolute height; entitlement = height < paidThrough
	periods      int64 // lifetime paid-period count
}

var (
	admin        address // may set fee, fee recipient, stage successor
	pendingAdmin address // staged by TransferAdmin, completes via AcceptAdmin
	feeRecipient address // may withdraw fees and sweep surplus
	feeBps       int64   // fee snapshotted into NEW plans

	self     address // this realm's address, captured at deploy
	nextPlan int64
	nextSub  int64

	plans       = avl.NewTree() // padID(id)                 -> *plan
	subs        = avl.NewTree() // padID(id)                 -> *sub
	activeByKey = avl.NewTree() // padID(planID)|subscriber  -> int64 sub id, while Active
	latestByKey = avl.NewTree() // padID(planID)|subscriber  -> most recent sub id, never removed
	providerNum = avl.NewTree() // address -> *int64, live plans per provider
	subNum      = avl.NewTree() // address -> *int64, Active subs per subscriber
	ledger      = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// --- provider side ---

// CreatePlan publishes a subscription plan and returns its id. No coins
// are accepted; the storage deposit the caller pays is the anti-spam.
// The current protocol fee is snapshotted into the plan and must not
// exceed maxFeeBps, the ceiling the provider signed for — pass
// MaxFeeBps to accept any legal fee. Plans are immutable once created:
// price and period changes are a new plan, so nothing a subscriber
// agreed to can move underneath them.
func CreatePlan(cur realm, title, description string, price, periodBlocks, maxFeeBps int64) int64 {
	assertNoSend()
	provider := cur.Previous().Address()

	if title == "" || len(title) > MaxTitleLen {
		panic("title must be 1.." + itoa(int64(MaxTitleLen)) + " bytes")
	}
	if len(description) > MaxDescLen {
		panic("description too long")
	}
	if price < MinPrice {
		panic("price must be at least " + itoa(MinPrice) + Denom)
	}
	if periodBlocks < MinPeriodBlocks || periodBlocks > MaxPeriodBlocks {
		panic("periodBlocks must be in [" + itoa(MinPeriodBlocks) + ", " +
			itoa(MaxPeriodBlocks) + "]")
	}
	if feeBps > maxFeeBps {
		panic("current fee " + itoa(feeBps) + " bps exceeds the caller's maximum " +
			itoa(maxFeeBps))
	}
	n := counter(providerNum, provider)
	if *n >= MaxPlansPerProvider {
		panic("per-provider plan limit reached")
	}

	id := nextPlan
	nextPlan++
	plans.Set(padID(id), &plan{
		id:           id,
		provider:     provider,
		title:        title,
		description:  description,
		price:        price,
		periodBlocks: periodBlocks,
		feeBps:       feeBps,
		status:       PlanActive,
	})
	*n++

	chain.Emit("PlanCreated",
		"planId", itoa(id),
		"provider", provider.String(),
		"price", itoa(price),
		"periodBlocks", itoa(periodBlocks),
		"feeBps", itoa(feeBps),
	)
	return id
}

// RetirePlan takes a plan off the market: no new subscriptions and no
// renewals. Provider only. Existing entitlements run to their
// paidThrough untouched; refusing renewals is subscriber protection —
// nobody keeps paying for a service whose provider announced its end.
// The provider's plan-quota slot frees.
func RetirePlan(cur realm, planID int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	p := mustGetPlan(planID)
	if caller != p.provider {
		panic("only the provider may retire a plan")
	}
	if p.status != PlanActive {
		panic("plan is not active")
	}
	p.status = PlanRetired
	*counter(providerNum, p.provider)--
	chain.Emit("PlanRetired", "planId", itoa(planID), "provider", p.provider.String())
}

// --- subscriber side ---

// Subscribe pays for the first billing period of a plan and returns the
// new subscription id. The transaction must attach EXACTLY the plan's
// price in ugnot — over- and underpayment are both refused, so a
// mistaken double-attach cannot silently become a donation. One
// subscriber holds at most one live subscription per plan: if an Active
// one exists the call is refused (the renewal path is Renew, never a
// second Subscribe — that is the duplicate-payment guard at the
// identity level); an incumbent past its grace window is collapsed to
// Expired in place, so a fresh start never waits on housekeeping.
//
// The payment settles immediately: price minus the plan's snapshotted
// fee to the provider's claimable balance, fee to the protocol pot.
// Entitlement runs from this block: paidThrough = height + periodBlocks.
func Subscribe(cur realm, planID int64) int64 {
	subscriber, amount := coinio.Receive(0, cur, Denom)
	p := mustGetPlan(planID)
	if p.status != PlanActive {
		panic("plan is not active")
	}
	if amount != p.price {
		panic("send exactly the plan price: " + itoa(p.price) + Denom)
	}

	key := padID(planID) + "|" + subscriber.String()
	if v := activeByKey.Get(key); v != nil {
		inc := mustGetSub(v.(int64))
		if runtime.ChainHeight() >= inc.paidThrough+inc.periodBlocks {
			expireInPlace(inc)
		} else if runtime.ChainHeight() >= inc.paidThrough {
			panic("subscription " + itoa(inc.id) + " to this plan is lapsed but renewable: " +
				"Renew back-pays the lapsed span and keeps the schedule; " +
				"Cancel then Subscribe restarts fresh at the same price")
		} else {
			panic("an active subscription to this plan already exists: renew it instead")
		}
	}
	n := counter(subNum, subscriber)
	if *n >= MaxSubsPerSubscriber {
		panic("per-subscriber subscription limit reached")
	}

	ledger.MustDeposit(p.provider.String(), amount, p.feeBps)

	id := nextSub
	nextSub++
	subs.Set(padID(id), &sub{
		id:           id,
		planID:       planID,
		subscriber:   subscriber,
		provider:     p.provider,
		price:        p.price,
		periodBlocks: p.periodBlocks,
		feeBps:       p.feeBps,
		status:       SubActive,
		paidThrough:  runtime.ChainHeight() + p.periodBlocks,
		periods:      1,
	})
	activeByKey.Set(key, id)
	latestByKey.Set(key, id)
	*n++
	p.subs++

	chain.Emit("Subscribed",
		"subId", itoa(id),
		"planId", itoa(planID),
		"subscriber", subscriber.String(),
		"provider", p.provider.String(),
		"amount", itoa(amount),
		"paidThrough", itoa(runtime.ChainHeight()+p.periodBlocks),
	)
	return id
}

// Renew pays for the next billing period of the caller's own
// subscription. The transaction must attach exactly the subscription's
// price. The renewal window is deterministic and stated in the header:
// accepted iff paidThrough - height <= periodBlocks (at most one full
// unstarted period prepaid — the duplicate-payment bound) and height <
// paidThrough + periodBlocks (the grace bound, exclusive — a renewal
// always buys at least one block). Extension is always
// FROM paidThrough, so period boundaries never drift, and a renewal
// inside grace covers the lapsed span — that is the price of keeping
// the original schedule, and it is the documented, deterministic
// choice.
func Renew(cur realm, subID int64) {
	payer, amount := coinio.Receive(0, cur, Denom)
	s := mustGetSub(subID)
	if payer != s.subscriber {
		panic("only the subscriber may renew")
	}
	if s.status != SubActive {
		panic("subscription is " + s.status)
	}
	p := mustGetPlan(s.planID)
	if p.status != PlanActive {
		panic("plan is retired; the paid period runs to its end but cannot be renewed")
	}
	if amount != s.price {
		panic("send exactly the subscription price: " + itoa(s.price) + Denom)
	}
	h := runtime.ChainHeight()
	if s.paidThrough-h > s.periodBlocks {
		panic("too early: at most one unstarted period may be prepaid; renewable from height " +
			itoa(s.paidThrough-s.periodBlocks))
	}
	if h >= s.paidThrough+s.periodBlocks {
		panic("grace window over; the subscription is expirable, subscribe afresh")
	}

	ledger.MustDeposit(s.provider.String(), amount, s.feeBps)
	s.paidThrough += s.periodBlocks
	s.periods++

	chain.Emit("Renewed",
		"subId", itoa(subID),
		"subscriber", s.subscriber.String(),
		"amount", itoa(amount),
		"paidThrough", itoa(s.paidThrough),
	)
}

// Cancel ends the caller's own subscription. Terminal: it can never be
// renewed afterwards, by anyone. No refund and no funds move — every
// payment settled when it was made, and the entitlement already bought
// (height < paidThrough) remains until it runs out. The plan slot and
// the subscriber's quota slot free immediately.
func Cancel(cur realm, subID int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	s := mustGetSub(subID)
	if caller != s.subscriber {
		panic("only the subscriber may cancel")
	}
	if s.status != SubActive {
		panic("subscription is " + s.status)
	}
	s.status = SubCancelled
	releaseSlots(s)
	chain.Emit("Cancelled",
		"subId", itoa(subID),
		"subscriber", s.subscriber.String(),
		"paidThrough", itoa(s.paidThrough),
	)
}

// Expire marks a lapsed subscription Expired once its grace window is
// over: height >= paidThrough + periodBlocks. Permissionless by design —
// like the sibling realms' valves, no slot's liveness may depend on
// either party showing up. No funds move.
func Expire(cur realm, subID int64) {
	assertNoSend()
	s := mustGetSub(subID)
	if s.status != SubActive {
		panic("subscription is " + s.status)
	}
	if runtime.ChainHeight() < s.paidThrough+s.periodBlocks {
		panic("not expirable: grace runs through height " +
			itoa(s.paidThrough+s.periodBlocks-1))
	}
	expireInPlace(s)
}

// --- payouts ---

// Claim sends amount ugnot of the caller's claimable balance back to
// the caller. Providers earn into this balance at every payment.
func Claim(cur realm, amount int64) {
	assertNoSend()
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

// WithdrawFees sends the accrued fee pot to the fee recipient. Only the
// fee recipient may call it, and only the pot moves.
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

// SweepDenom recovers out-of-band coins (sent by raw bank transfer,
// outside any entrypoint) to the fee recipient. For the ledger denom
// the reserve is Liabilities() — user balances and the fee pot are
// structurally unreachable. Fee recipient only.
func SweepDenom(cur realm, denom string) {
	assertNoSend()
	if cur.Previous().Address() != feeRecipient {
		panic("fee recipient only")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = ledger.Liabilities()
	}
	// coinio.Sweep itself aborts when nothing sits above the reserve.
	swept := coinio.Sweep(0, cur, feeRecipient, denom, reserve)
	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", itoa(swept)+denom)
}

// --- administration ---

// SetFeeBps sets the protocol fee snapshotted into FUTURE plans.
// Bounded by MaxFeeBps; existing plans and subscriptions are untouched
// — their fee was fixed the moment the provider consented to it.
func SetFeeBps(cur realm, bps int64) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	if bps < 0 || bps > MaxFeeBps {
		panic("fee must be in [0, " + itoa(MaxFeeBps) + "] bps")
	}
	old := feeBps
	feeBps = bps
	chain.Emit("FeeChanged", "oldBps", itoa(old), "newBps", itoa(bps))
}

// SetFeeRecipient points future fee withdrawals and sweeps at a new
// address. Admin only. The zero address is refused — it would strand
// the pot.
func SetFeeRecipient(cur realm, recipient address) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	var zero address
	if recipient == zero {
		panic("fee recipient must not be the zero address")
	}
	old := feeRecipient
	feeRecipient = recipient
	chain.Emit("FeeRecipientChanged", "old", old.String(), "new", recipient.String())
}

// TransferAdmin stages a two-step admin handover. The successor holds
// nothing until AcceptAdmin.
func TransferAdmin(cur realm, successor address) {
	assertNoSend()
	assertAdmin(cur.Previous().Address())
	var zero address
	if successor == zero {
		panic("successor must not be the zero address")
	}
	pendingAdmin = successor
	chain.Emit("AdminTransferStaged", "from", admin.String(), "to", successor.String())
}

// AcceptAdmin completes the handover; only the staged successor may.
func AcceptAdmin(cur realm) {
	assertNoSend()
	caller := cur.Previous().Address()
	if caller != pendingAdmin {
		panic("only the staged successor may accept")
	}
	old := admin
	admin = caller
	var zero address
	pendingAdmin = zero
	chain.Emit("AdminTransferred", "from", old.String(), "to", admin.String())
}

// --- views ---

// Entitled reports whether the subscription's paid entitlement covers
// the current block: height < paidThrough. Status deliberately does not
// enter into it — a cancelled subscriber keeps what they paid for, and
// an expirable-but-unexpired one has already lapsed here.
func Entitled(subID int64) bool {
	s := mustGetSub(subID)
	return runtime.ChainHeight() < s.paidThrough
}

// EntitledFor reports whether subscriber currently holds paid
// entitlement to planID, through their MOST RECENT subscription to it.
// This is the one-call integration surface for other realms and
// services, and it honors the entitlement contract across status: a
// cancelled subscription keeps answering true until its paidThrough —
// what was bought stays bought (audit finding Y1). One self-inflicted
// edge is fail-closed: cancelling a prepaid subscription and
// re-subscribing at once points this surface at the NEW, earlier
// paidThrough; the old subscription's remaining span stays queryable
// per-id via Entitled.
func EntitledFor(planID int64, subscriber address) bool {
	v := latestByKey.Get(padID(planID) + "|" + subscriber.String())
	if v == nil {
		return false
	}
	return Entitled(v.(int64))
}

// ActiveSubID returns the caller-facing id of subscriber's live
// subscription to planID, or (0, false) if none is Active.
func ActiveSubID(planID int64, subscriber address) (int64, bool) {
	v := activeByKey.Get(padID(planID) + "|" + subscriber.String())
	if v == nil {
		return 0, false
	}
	return v.(int64), true
}

// PlanInfo returns a plan's public fields.
func PlanInfo(planID int64) (provider address, title string, price, periodBlocks, planFeeBps int64, status string, lifetimeSubs int64) {
	p := mustGetPlan(planID)
	return p.provider, p.title, p.price, p.periodBlocks, p.feeBps, p.status, p.subs
}

// SubInfo returns a subscription's public fields.
func SubInfo(subID int64) (planID int64, subscriber, provider address, price, paidThrough, periods int64, status string) {
	s := mustGetSub(subID)
	return s.planID, s.subscriber, s.provider, s.price, s.paidThrough, s.periods, s.status
}

// PaidThrough returns the absolute height a subscription is paid to.
func PaidThrough(subID int64) int64 { return mustGetSub(subID).paidThrough }

// RenewableFrom returns the earliest height at which Renew will accept
// a payment for this subscription, and the last height at which it
// still will (inclusive) — the deterministic window, precomputed for
// integrators. From until+1 the subscription is expirable instead; the
// two sets partition exactly.
func RenewableFrom(subID int64) (from, until int64) {
	s := mustGetSub(subID)
	return s.paidThrough - s.periodBlocks, s.paidThrough + s.periodBlocks - 1
}

func Admin() address            { return admin }
func PendingAdmin() address     { return pendingAdmin }
func FeeRecipient() address     { return feeRecipient }
func FeeBps() int64             { return feeBps }
func NumPlans() int64           { return nextPlan }
func NumSubs() int64            { return nextSub }
func UsersTotal() int64         { return ledger.UsersTotal() }
func FeesAccrued() int64        { return ledger.FeesAccrued() }
func Liabilities() int64        { return ledger.Liabilities() }
func BalanceOf(a address) int64 { return ledger.BalanceOf(a.String()) }
func Address() address          { return self }
func Held() int64               { return coinio.HeldAt(self, Denom) }

// --- render ---

func Render(path string) string {
	if path == "" {
		return renderHome()
	}
	return "unknown page; try the realm root"
}

func renderHome() string {
	out := "# subscriptions\n\n"
	out += "Provider-published plans, per-period payment, deterministic " +
		"renewal, grace, expiration and cancellation. Entitlement is " +
		"`height < paidThrough`, queryable by anyone.\n\n"
	out += "- plans: " + itoa(nextPlan) + "\n"
	out += "- subscriptions: " + itoa(nextSub) + "\n"
	out += "- provider balances: " + itoa(ledger.UsersTotal()) + Denom + "\n"
	out += "- fees accrued: " + itoa(ledger.FeesAccrued()) + Denom + "\n"
	out += "- current fee for new plans: " + itoa(feeBps) + " bps (cap " +
		itoa(MaxFeeBps) + ")\n\n"

	if nextPlan == 0 {
		return out + "No plans yet.\n"
	}
	out += "## newest plans\n\n"
	shown := int64(0)
	for id := nextPlan - 1; id >= 0 && shown < RenderLimit; id-- {
		p := mustGetPlan(id)
		out += "- #" + itoa(p.id) + " **" + sanitize.InlineText(p.title) +
			"** — " + itoa(p.price) + Denom + " / " + itoa(p.periodBlocks) +
			" blocks, " + p.status + ", provider `" + p.provider.String() +
			"`, " + itoa(p.subs) + " lifetime subs\n"
		shown++
	}
	if nextPlan > shown {
		out += "\n(" + itoa(nextPlan-shown) + " older plans not shown)\n"
	}
	return out
}

// --- internals ---

// expireInPlace flips an Active subscription to Expired and frees its
// slots. Callers have already established expirability.
func expireInPlace(s *sub) {
	s.status = SubExpired
	releaseSlots(s)
	chain.Emit("SubscriptionExpired",
		"subId", itoa(s.id),
		"subscriber", s.subscriber.String(),
		"paidThrough", itoa(s.paidThrough),
	)
}

// releaseSlots removes the plan|subscriber activity index entry and
// decrements the subscriber's quota counter. Exactly once per terminal
// transition, which both terminal paths guarantee by requiring
// SubActive first.
func releaseSlots(s *sub) {
	activeByKey.Remove(padID(s.planID) + "|" + s.subscriber.String())
	*counter(subNum, s.subscriber)--
}

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

func mustGetPlan(id int64) *plan {
	v := plans.Get(padID(id))
	if v == nil {
		panic("unknown plan id")
	}
	return v.(*plan)
}

func mustGetSub(id int64) *sub {
	v := subs.Get(padID(id))
	if v == nil {
		panic("unknown subscription id")
	}
	return v.(*sub)
}

// counter returns the persistent per-address counter in tree,
// allocating a zero on first use.
func counter(tree *avl.Tree, a address) *int64 {
	k := a.String()
	if v := tree.Get(k); v != nil {
		return v.(*int64)
	}
	n := new(int64)
	tree.Set(k, n)
	return n
}

func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
