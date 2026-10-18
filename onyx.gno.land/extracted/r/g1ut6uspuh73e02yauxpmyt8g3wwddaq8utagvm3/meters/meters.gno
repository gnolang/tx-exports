// Realm meters is usage-based billing with graduated marginal pricing: a
// provider publishes a METER (a unit of service, a list price per unit, a
// billing period, and a tiers.Schedule of marginal volume discounts), a
// consumer ENROLLS and prepays a deposit, the provider RECORDS usage as it is
// served, and each period's accumulated usage settles from the consumer's
// deposit into the provider's claimable balance.
//
// It is the usage-based complement to r/subscriptions' flat recurring plans —
// the one billing shape this portfolio lacked (its discovery gate's whole
// finding). The pricing identity is p/tiers':
//
//	base = units × unitPrice        (checked int64 multiplication)
//	due  = Schedule.Charge(base)    (≤ base — marginal discount off list)
//
// tiers validates every rate into [0, RateScale], so Charge(base) ≤ base is an
// arithmetic fact: a schedule can DISCOUNT list price and can never surcharge
// it. A flat price is the one-rate schedule (no edges, rates "10000") — the
// degenerate case, not a second code path.
//
// # The three trust statements, in order of who bears what
//
//   - USAGE IS PROVIDER-ASSERTED, and that declaration is the trust boundary —
//     the same boundary r/books draws at owner-posted entries and r/cashflow
//     at Policy.Cash. The realm cannot verify off-chain consumption; what it
//     does is make the assertion attributable (only the meter's provider may
//     Record, and only against an enrollment to that meter), bounded (next
//     statement), and auditable (every unit is an event and a readable row).
//   - LIABILITY IS BOUNDED BY DEPOSIT, fail-closed. Record refuses any posting
//     whose end-of-period charge would exceed the enrollment's deposited
//     balance, and a withdrawal leaves the pending charge covered. Charge is
//     monotone in units (tiers' documented monotonicity), so the refusal
//     predicate is well-defined. No arrears exist anywhere in this design: the
//     realm never holds a claim against funds a consumer has not deposited.
//   - SETTLEMENT IS LAZY AND EXACT. Usage accumulates against the period it
//     was recorded in; the first touch after a period boundary settles that
//     period's charge. A period nobody recorded usage in owes zero, so lazy
//     settlement loses nothing — there is no keeper, no upkeep dependency, and
//     a Settle valve is permissionless so neither party's absence can wedge
//     the other's funds.
//
// Funds move on pull paths only: providers Claim, consumers WithdrawDeposit or
// Exit, the fee recipient WithdrawFees. Periods are fixed-length block windows
// anchored at Enroll height — runtime.ChainHeight() throughout, never a
// caller-supplied time (r/books' obligation, inherited verbatim).
//
// REALM-CALLER CAVEAT, inherited from the siblings verbatim: coinio's receipt
// guard admits only EOA payers, so enrolling consumers are EOAs; assertNoSend
// reads the ORIGIN envelope, so every non-payable function refuses any
// transaction that attached coins anywhere. Providers may be EOAs or realms,
// but a realm provider must expose its own crossing path to Claim, or what it
// earns is stranded.
package meters

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/coinio"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/feeledger"
	"gno.land/p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/tiers"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Denom is the only asset this realm accepts.
const Denom = "ugnot"

// MaxFeeBps is the hard protocol-fee cap: 1000 bps = 10%.
const MaxFeeBps = int64(1000)

// Meter status values.
const (
	MeterActive  = "active"
	MeterRetired = "retired"
)

// Enrollment status values. Exited is terminal.
const (
	EnrollActive = "active"
	EnrollExited = "exited"
)

// Input bounds.
const (
	MaxTitleLen = 80
	MaxUnitLen  = 24

	// MinUnitPrice keeps a meter from being free-by-rounding; a provider
	// who wants a free tier declares a 0-rate first tier instead, which
	// keeps the arithmetic visible in the schedule rather than implicit
	// in a zero price.
	MinUnitPrice = int64(1)
	// MaxUnitPrice keeps base = units × unitPrice far from int64
	// overflow for any usage a deposit could plausibly cover; the
	// checked multiplication is still there and still refuses.
	MaxUnitPrice = int64(1_000_000_000) // 1000 GNOT per unit

	// MinPeriodBlocks/MaxPeriodBlocks bound a meter's billing period —
	// the same bounds and reasoning as r/subscriptions: the floor keeps
	// settlement from becoming a per-block treadmill, the ceiling keeps
	// period arithmetic far from overflow.
	MinPeriodBlocks = int64(10)
	MaxPeriodBlocks = int64(7500000)

	// MaxMetersPerProvider bounds catalog monopolization by a single
	// address — the finding that was RED in permission_registry and
	// service_registry, carried from the start here.
	MaxMetersPerProvider = 20

	// MaxEnrollmentsPerConsumer bounds one account's open-enrollment
	// state. Exited enrollments free their slot.
	MaxEnrollmentsPerConsumer = 100

	// RenderLimit bounds every rendered list — an unbounded Render was
	// YELLOW in three prior audits.
	RenderLimit = 20
)

type meter struct {
	id           int64
	provider     address
	title        string
	unit         string // what one unit is, for humans: "call", "GB", "seat-day"
	unitPrice    int64  // ugnot list price per unit
	sched        tiers.Schedule
	periodBlocks int64
	feeBps       int64 // snapshotted at creation, charged at every settlement
	status       string
	enrollments  int64 // lifetime count, never decremented
}

type enrollment struct {
	id       int64
	meterID  int64
	consumer address
	provider address // copied at Enroll; never re-read from the meter
	// pricing terms, all copied at Enroll so nothing a consumer agreed
	// to can move underneath them (meters are immutable anyway; the
	// copy makes that a structural fact of the enrollment rather than
	// a property of the meter's lifecycle):
	unitPrice    int64
	sched        tiers.Schedule
	periodBlocks int64
	feeBps       int64

	status      string
	startHeight int64 // period anchor: period k is [start+k·p, start+(k+1)·p)
	usage       int64 // units recorded in period usagePeriod, not yet settled
	usagePeriod int64 // the period index usage belongs to
	periods     int64 // lifetime settled-period count (nonzero charges only)
}

var (
	admin        address // may set fee, fee recipient, stage successor
	pendingAdmin address // staged by TransferAdmin, completes via AcceptAdmin
	feeRecipient address // may withdraw fees and sweep surplus
	feeBps       int64   // fee snapshotted into NEW meters

	self      address // this realm's address, captured at deploy
	nextMeter int64
	nextEnr   int64

	metersT     = avl.NewTree() // padID(id)              -> *meter
	enrollments = avl.NewTree() // padID(id)              -> *enrollment
	activeByKey = avl.NewTree() // padID(meterID)|consumer -> int64 enroll id, while Active
	providerNum = avl.NewTree() // address -> *int64, live meters per provider
	consumerNum = avl.NewTree() // address -> *int64, Active enrollments per consumer
	ledger      = feeledger.MustNew(MaxFeeBps)
)

func init() {
	admin = unsafe.OriginCaller()
	feeRecipient = admin
	self = unsafe.CurrentRealm().Address()
}

// --- provider side ---

// CreateMeter publishes a meter and returns its id. No coins are accepted; the
// storage deposit the caller pays is the anti-spam. edges and rates are
// comma-separated int64 lists building the tiers.Schedule over the ugnot BASE
// (units × unitPrice): len(rates) == len(edges)+1, each rate in [0, 10000]
// ten-thousandths of list price. "" edges with rates "10000" is a flat meter.
// The current protocol fee is snapshotted in and must not exceed maxFeeBps,
// the ceiling the provider signed for — pass MaxFeeBps to accept any legal
// fee. Meters are immutable once created: price, period or schedule changes
// are a new meter, so nothing a consumer agreed to can move underneath them.
func CreateMeter(cur realm, title, unit string, unitPrice, periodBlocks int64, edges, rates string, maxFeeBps int64) int64 {
	assertNoSend()
	provider := cur.Previous().Address()

	if title == "" || len(title) > MaxTitleLen {
		panic("title must be 1.." + itoa(MaxTitleLen) + " bytes")
	}
	if unit == "" || len(unit) > MaxUnitLen {
		panic("unit must be 1.." + itoa(MaxUnitLen) + " bytes")
	}
	if unitPrice < MinUnitPrice || unitPrice > MaxUnitPrice {
		panic("unitPrice must be " + itoa(MinUnitPrice) + ".." + itoa(MaxUnitPrice) + Denom)
	}
	if periodBlocks < MinPeriodBlocks || periodBlocks > MaxPeriodBlocks {
		panic("periodBlocks must be " + itoa(MinPeriodBlocks) + ".." + itoa(MaxPeriodBlocks))
	}
	if maxFeeBps < 0 || maxFeeBps > MaxFeeBps {
		panic("maxFeeBps must be 0.." + itoa(MaxFeeBps))
	}
	if feeBps > maxFeeBps {
		panic("current protocol fee " + itoa(feeBps) + " bps exceeds the ceiling you signed for (" + itoa(maxFeeBps) + ")")
	}
	s, err := tiers.New(
		parseInt64List(edges, tiers.MaxTiers-1, "edge"),
		parseInt64List(rates, tiers.MaxTiers, "rate"),
	)
	if err != nil {
		panic("schedule: " + err.Error())
	}

	n := counter(providerNum, provider)
	if *n >= MaxMetersPerProvider {
		panic("per-provider meter limit reached")
	}

	id := nextMeter
	nextMeter++
	metersT.Set(padID(id), &meter{
		id:           id,
		provider:     provider,
		title:        title,
		unit:         unit,
		unitPrice:    unitPrice,
		sched:        s,
		periodBlocks: periodBlocks,
		feeBps:       feeBps,
		status:       MeterActive,
	})
	*n++

	chain.Emit("MeterCreated",
		"meterId", itoa(id),
		"provider", provider.String(),
		"unitPrice", itoa(unitPrice),
		"periodBlocks", itoa(periodBlocks),
		"feeBps", itoa(feeBps),
	)
	return id
}

// RetireMeter stops NEW enrollments and NEW usage on the caller's own meter.
// Existing enrollments keep their funds paths whole: pending usage still
// settles, deposits stay withdrawable, Exit still refunds. The provider's
// meter slot frees. Terminal.
func RetireMeter(cur realm, meterID int64) {
	assertNoSend()
	m := mustGetMeter(meterID)
	if cur.Previous().Address() != m.provider {
		panic("only the provider may retire a meter")
	}
	if m.status != MeterActive {
		panic("meter is " + m.status)
	}
	m.status = MeterRetired
	decCounter(providerNum, m.provider)
	chain.Emit("MeterRetired", "meterId", itoa(meterID), "provider", m.provider.String())
}

// Record asserts that the enrollment's consumer used units more units of the
// meter's service in the CURRENT period. Provider only. Fail-closed on the
// deposit bound: if charging the period's new total at the enrollment's
// schedule would exceed the deposited balance, the whole posting is refused —
// never clipped, because a clipped assertion is a wrong assertion with the
// same signature as a right one. Any elapsed period settles first, so the
// bound is always measured against the balance that will actually back this
// period.
func Record(cur realm, enrollID, units int64) {
	assertNoSend()
	e := mustGetEnrollment(enrollID)
	if cur.Previous().Address() != e.provider {
		panic("only the provider may record usage")
	}
	if e.status != EnrollActive {
		panic("enrollment is " + e.status)
	}
	m := mustGetMeter(e.meterID)
	if m.status != MeterActive {
		panic("meter is " + m.status + "; no new usage")
	}
	if units <= 0 {
		panic("units must be positive")
	}
	settleElapsed(e)

	newUsage, ok := addChecked(e.usage, units)
	if !ok {
		panic("usage overflow")
	}
	charge := chargeFor(e, newUsage)
	bal := ledger.BalanceOf(enrollKey(e.id))
	if charge > bal {
		panic("deposit bound: charging " + itoa(newUsage) + " units costs " + itoa(charge) +
			Denom + " against a balance of " + itoa(bal) + Denom +
			" — the consumer must deposit before this usage can be recorded")
	}
	e.usage = newUsage

	chain.Emit("UsageRecorded",
		"enrollId", itoa(enrollID),
		"meterId", itoa(e.meterID),
		"units", itoa(units),
		"periodUsage", itoa(newUsage),
		"period", itoa(e.usagePeriod),
		"pendingCharge", itoa(charge),
	)
}

// --- consumer side ---

// Enroll opens an enrollment on a meter for the caller, with any attached
// coins credited as the initial deposit. One active enrollment per
// (meter, consumer); Exit frees the slot. Terms (price, schedule, period,
// fee) are copied in at this moment and never re-read.
func Enroll(cur realm, meterID int64) int64 {
	// The deposit is optional at enrollment: with coins attached the payer is
	// the EOA origin coinio's receipt guard admits, without them the caller is
	// taken as-is. A REALM may therefore enroll coinless, but it can never
	// fund the enrollment afterwards (Deposit's payer comes through the same
	// EOA-only guard), so a realm enrollment is inert rather than unsafe.
	consumer := cur.Previous().Address()
	amount := int64(0)
	if !unsafe.OriginSend().IsZero() {
		consumer, amount = coinio.Receive(0, cur, Denom)
	}
	m := mustGetMeter(meterID)
	if m.status != MeterActive {
		panic("meter is " + m.status)
	}
	key := padID(meterID) + "|" + consumer.String()
	if activeByKey.Get(key) != nil {
		panic("an active enrollment on this meter already exists")
	}
	n := counter(consumerNum, consumer)
	if *n >= MaxEnrollmentsPerConsumer {
		panic("per-consumer enrollment limit reached")
	}

	if amount > 0 {
		ledger.MustDeposit(enrollKey(nextEnr), amount, 0)
	}

	id := nextEnr
	nextEnr++
	enrollments.Set(padID(id), &enrollment{
		id:           id,
		meterID:      meterID,
		consumer:     consumer,
		provider:     m.provider,
		unitPrice:    m.unitPrice,
		sched:        m.sched,
		periodBlocks: m.periodBlocks,
		feeBps:       m.feeBps,
		status:       EnrollActive,
		startHeight:  runtime.ChainHeight(),
		usagePeriod:  0,
	})
	activeByKey.Set(key, id)
	*n++
	m.enrollments++

	chain.Emit("Enrolled",
		"enrollId", itoa(id),
		"meterId", itoa(meterID),
		"consumer", consumer.String(),
		"deposit", itoa(amount),
	)
	return id
}

// Deposit adds the attached coins to the caller's own enrollment deposit.
// Elapsed usage settles first, so a top-up lands on a current balance.
func Deposit(cur realm, enrollID int64) {
	payer, amount := coinio.Receive(0, cur, Denom)
	e := mustGetEnrollment(enrollID)
	if payer != e.consumer {
		panic("only the consumer may deposit")
	}
	if e.status != EnrollActive {
		panic("enrollment is " + e.status)
	}
	if amount <= 0 {
		panic("attach the deposit to the call")
	}
	settleElapsed(e)
	ledger.MustDeposit(enrollKey(enrollID), amount, 0)
	chain.Emit("Deposited",
		"enrollId", itoa(enrollID),
		"amount", itoa(amount),
		"balance", itoa(ledger.BalanceOf(enrollKey(enrollID))),
	)
}

// WithdrawDeposit returns amount of the caller's own enrollment deposit.
// The current period's pending charge stays covered: withdrawable is
// balance − Charge(current usage), so a provider's already-recorded usage can
// never be defunded. Elapsed usage settles first.
func WithdrawDeposit(cur realm, enrollID, amount int64) {
	assertNoSend()
	e := mustGetEnrollment(enrollID)
	caller := cur.Previous().Address()
	if caller != e.consumer {
		panic("only the consumer may withdraw the deposit")
	}
	if e.status != EnrollActive {
		panic("enrollment is " + e.status)
	}
	if amount <= 0 {
		panic("amount must be positive")
	}
	settleElapsed(e)
	pending := chargeFor(e, e.usage)
	free := ledger.BalanceOf(enrollKey(enrollID)) - pending
	if amount > free {
		panic("withdrawable is " + itoa(free) + Denom + " (balance minus the pending charge " +
			itoa(pending) + Denom + ")")
	}
	ledger.MustWithdraw(enrollKey(enrollID), amount)
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("DepositWithdrawn",
		"enrollId", itoa(enrollID),
		"amount", itoa(amount),
	)
}

// Exit closes the caller's own enrollment: elapsed periods settle, the
// CURRENT period's recorded usage settles immediately (the provider served
// it; exiting is not an escape from it), the remaining deposit refunds in
// full, and the slot frees. Terminal.
func Exit(cur realm, enrollID int64) {
	assertNoSend()
	e := mustGetEnrollment(enrollID)
	caller := cur.Previous().Address()
	if caller != e.consumer {
		panic("only the consumer may exit")
	}
	if e.status != EnrollActive {
		panic("enrollment is " + e.status)
	}
	settleElapsed(e)
	settleUsage(e) // the current partial period, charged on what was consumed

	refund, err := ledger.WithdrawAll(enrollKey(enrollID))
	if err != nil {
		panic(err)
	}
	e.status = EnrollExited
	activeByKey.Remove(padID(e.meterID) + "|" + e.consumer.String())
	decCounter(consumerNum, e.consumer)
	if refund > 0 {
		coinio.Payout(0, cur, caller, Denom, refund)
	}
	chain.Emit("Exited",
		"enrollId", itoa(enrollID),
		"refund", itoa(refund),
	)
}

// Settle settles any fully-elapsed period of an enrollment. Permissionless by
// design — like the sibling realms' valves, no settlement's liveness may
// depend on either party showing up. No coins may ride on it, and calling it
// on an enrollment with nothing elapsed is a refused no-op so the event
// stream never carries empty settlements.
func Settle(cur realm, enrollID int64) {
	assertNoSend()
	e := mustGetEnrollment(enrollID)
	if e.status != EnrollActive {
		panic("enrollment is " + e.status)
	}
	if currentPeriod(e) <= e.usagePeriod {
		panic("nothing to settle: the current period is still open")
	}
	settleElapsed(e)
}

// --- payouts ---

// Claim sends amount ugnot of the caller's claimable balance back to the
// caller. Providers earn into this balance at every settlement.
func Claim(cur realm, amount int64) {
	assertNoSend()
	caller := cur.Previous().Address()
	if err := ledger.Withdraw(caller.String(), amount); err != nil {
		panic(err)
	}
	coinio.Payout(0, cur, caller, Denom, amount)
	chain.Emit("Claim", "to", caller.String(), "amount", itoa(amount))
}

// ClaimAll sends the caller's entire claimable balance back to the caller.
// Fails if there is nothing to claim.
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

// WithdrawFees sends the accrued fee pot to the fee recipient. Only the fee
// recipient may call it, and only the pot moves.
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

// SweepDenom recovers out-of-band coins (sent by raw bank transfer, outside
// any entrypoint) to the fee recipient. For the ledger denom the reserve is
// Liabilities() — user balances and the fee pot are structurally unreachable.
// Fee recipient only.
func SweepDenom(cur realm, denom string) {
	assertNoSend()
	if cur.Previous().Address() != feeRecipient {
		panic("fee recipient only")
	}
	reserve := int64(0)
	if denom == Denom {
		reserve = ledger.Liabilities()
	}
	swept := coinio.Sweep(0, cur, feeRecipient, denom, reserve)
	chain.Emit("SurplusSwept", "to", feeRecipient.String(), "coins", itoa(swept)+denom)
}

// --- administration (two-step transfer, the house pattern) ---

// SetFeeBps sets the protocol fee snapshotted into NEW meters. Admin only.
// No existing meter or enrollment moves.
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

// SetFeeRecipient points fee withdrawal and sweeps at recipient. Admin only.
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

// TransferAdmin stages successor as the next admin; AcceptAdmin completes it.
// Two-step with consent — a one-step transfer bricked resources in two prior
// audits (service_registry Y4, permission_registry Y4).
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

// AcceptAdmin completes a staged admin transfer. Pending admin only.
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

// PriceOf prices units of meter meterID at its schedule: the charge a period
// closing at exactly that usage would settle. The quote every consumer can
// take before enrolling and every provider can show beside an invoice.
func PriceOf(meterID, units int64) int64 {
	m := mustGetMeter(meterID)
	if units < 0 {
		panic("units must be non-negative")
	}
	base, ok := mulChecked(units, m.unitPrice)
	if !ok {
		panic("base overflow")
	}
	c, err := m.sched.Charge(base)
	if err != nil {
		panic("charge: " + err.Error())
	}
	return c
}

// PendingChargeOf is the charge the enrollment's current recorded usage would
// settle at — what WithdrawDeposit holds back.
func PendingChargeOf(enrollID int64) int64 {
	e := mustGetEnrollment(enrollID)
	return chargeFor(e, e.usage)
}

// BalanceOf is an enrollment's deposited balance as the LEDGER holds it —
// including a not-yet-settled elapsed period's charge; net view: subtract
// PendingChargeOf.
func BalanceOf(enrollID int64) int64 {
	mustGetEnrollment(enrollID)
	return ledger.BalanceOf(enrollKey(enrollID))
}

// ChargeHeadroomOf is how much MORE charge the current period could absorb
// before Record's deposit bound refuses: balance − pending charge.
func ChargeHeadroomOf(enrollID int64) int64 {
	e := mustGetEnrollment(enrollID)
	return ledger.BalanceOf(enrollKey(enrollID)) - chargeFor(e, e.usage)
}

// MeterInfo returns a meter's terms.
func MeterInfo(meterID int64) (provider address, title, unit string, unitPrice, periodBlocks, meterFeeBps int64, status string, lifetimeEnrollments int64) {
	m := mustGetMeter(meterID)
	return m.provider, m.title, m.unit, m.unitPrice, m.periodBlocks, m.feeBps, m.status, m.enrollments
}

// ScheduleOf returns a meter's schedule as its edge and rate slices.
func ScheduleOf(meterID int64) (edges, rates []int64) {
	m := mustGetMeter(meterID)
	return m.sched.Edges(), m.sched.Rates()
}

// EnrollInfo returns an enrollment's state. usage/usagePeriod are the raw
// accumulator — an elapsed, unsettled period reads here exactly as it will
// settle.
func EnrollInfo(enrollID int64) (meterID int64, consumer, provider address, status string, startHeight, usage, usagePeriod, settledPeriods int64) {
	e := mustGetEnrollment(enrollID)
	return e.meterID, e.consumer, e.provider, e.status, e.startHeight, e.usage, e.usagePeriod, e.periods
}

// ActiveEnrollID resolves the caller-free (meter, consumer) index.
func ActiveEnrollID(meterID int64, consumer address) (int64, bool) {
	v := activeByKey.Get(padID(meterID) + "|" + consumer.String())
	if v == nil {
		return 0, false
	}
	return v.(int64), true
}

// CurrentPeriodOf is the period index now open for an enrollment.
func CurrentPeriodOf(enrollID int64) int64 { return currentPeriod(mustGetEnrollment(enrollID)) }

func Admin() address            { return admin }
func PendingAdmin() address     { return pendingAdmin }
func FeeRecipient() address     { return feeRecipient }
func FeeBps() int64             { return feeBps }
func NumMeters() int64          { return nextMeter }
func NumEnrollments() int64     { return nextEnr }
func UsersTotal() int64         { return ledger.UsersTotal() }
func FeesAccrued() int64        { return ledger.FeesAccrued() }
func Liabilities() int64        { return ledger.Liabilities() }
func ClaimableOf(a address) int64 { return ledger.BalanceOf(a.String()) }
func Held() int64               { return coinio.HeldAt(self, Denom) }
func Address() address          { return self }
func Height() int64             { return runtime.ChainHeight() }

// --- internals ---

// currentPeriod is the index of the period open at the chain head.
func currentPeriod(e *enrollment) int64 {
	return (runtime.ChainHeight() - e.startHeight) / e.periodBlocks
}

// chargeFor prices usage units at the enrollment's copied terms.
func chargeFor(e *enrollment, usage int64) int64 {
	if usage == 0 {
		return 0
	}
	base, ok := mulChecked(usage, e.unitPrice)
	if !ok {
		panic("base overflow")
	}
	c, err := e.sched.Charge(base)
	if err != nil {
		panic("charge: " + err.Error())
	}
	return c
}

// settleElapsed settles the usage accumulator if its period has closed, then
// re-anchors the accumulator on the current period. Exact because usage can
// only ever belong to one period: periods between usagePeriod and now had no
// recorded usage and so owe zero.
func settleElapsed(e *enrollment) {
	cp := currentPeriod(e)
	if cp <= e.usagePeriod {
		return
	}
	settleUsage(e)
	e.usagePeriod = cp
}

// settleUsage charges the accumulator where it stands and moves the funds:
// enrollment deposit -> provider claimable, protocol fee split at the
// enrollment's snapshotted bps. Record's deposit bound is what guarantees the
// withdrawal cannot fail; if that invariant were ever broken the ledger's own
// refusal aborts the whole transaction rather than under-settling.
func settleUsage(e *enrollment) {
	if e.usage == 0 {
		return
	}
	charge := chargeFor(e, e.usage)
	// A zero charge is a LEGAL settlement, not a degenerate one: the realm's
	// own doc recommends a 0-rate first tier for free allowances, and the
	// per-slice floor prices small bases at 0 under positive rates too. The
	// ledger refuses a zero-amount move (feeledger: amount must be positive),
	// so an unconditional MustWithdraw here panics and WEDGES the enrollment
	// forever -- every path to its funds routes through this function. Audit
	// finding R1. The accumulator still clears; nothing is owed, so nothing
	// moves, no period is counted settled and no Settled event is emitted
	// (the event stream carries funds moves, not free usage).
	if charge > 0 {
		ledger.MustWithdraw(enrollKey(e.id), charge)
		credited, fee := ledger.MustDeposit(e.provider.String(), charge, e.feeBps)
		e.periods++
		chain.Emit("Settled",
			"enrollId", itoa(e.id),
			"meterId", itoa(e.meterID),
			"period", itoa(e.usagePeriod),
			"units", itoa(e.usage),
			"charge", itoa(charge),
			"credited", itoa(credited),
			"fee", itoa(fee),
		)
	}
	e.usage = 0
}

func mustGetMeter(id int64) *meter {
	v := metersT.Get(padID(id))
	if v == nil {
		panic("unknown meter " + itoa(id))
	}
	return v.(*meter)
}

func mustGetEnrollment(id int64) *enrollment {
	v := enrollments.Get(padID(id))
	if v == nil {
		panic("unknown enrollment " + itoa(id))
	}
	return v.(*enrollment)
}

// enrollKey is the ledger account an enrollment's deposit lives under. It
// cannot collide with a provider's claimable account: addresses never start
// with '#'.
func enrollKey(id int64) string { return "#enr|" + padID(id) }

// assertNoSend refuses coins on every non-payable entrypoint. Reads the
// ORIGIN envelope, so a transaction that attached coins anywhere is refused
// even if an intermediary consumed them.
func assertNoSend() {
	if !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

// counter returns the live-count cell for a, creating it at zero.
func counter(tree *avl.Tree, a address) *int64 {
	k := a.String()
	if v := tree.Get(k); v != nil {
		return v.(*int64)
	}
	n := int64(0)
	tree.Set(k, &n)
	return &n
}

// decCounter decrements a's live count and removes the cell at zero — the
// index must not accumulate dead keys (service_registry's lesson).
func decCounter(tree *avl.Tree, a address) {
	k := a.String()
	v := tree.Get(k)
	if v == nil {
		panic("counter underflow: no cell for " + k)
	}
	n := v.(*int64)
	*n--
	if *n < 0 {
		panic("counter underflow for " + k)
	}
	if *n == 0 {
		tree.Remove(k)
	}
}

// parseInt64List parses a comma-separated int64 list, bounding the element
// count BEFORE materialising values so a thousand-element string dies on
// count, not memory (r/receivables' bounding argument). "" is the empty list.
func parseInt64List(s string, max int, what string) []int64 {
	if s == "" {
		return nil
	}
	var out []int64
	start := 0
	for i := 0; i <= len(s); i++ {
		if i < len(s) && s[i] != ',' {
			continue
		}
		if len(out) >= max {
			panic("too many " + what + "s: at most " + strconv.Itoa(max))
		}
		field := s[start:i]
		start = i + 1
		n, err := strconv.ParseInt(trimSpaces(field), 10, 64)
		if err != nil {
			panic("bad " + what + " " + field + ": " + err.Error())
		}
		out = append(out, n)
	}
	return out
}

func trimSpaces(s string) string {
	i, j := 0, len(s)
	for i < j && s[i] == ' ' {
		i++
	}
	for j > i && s[j-1] == ' ' {
		j--
	}
	return s[i:j]
}

// addChecked / mulChecked are int64 overflow-checked arithmetic. Written here
// rather than imported because they are two lines each and the house keeps
// its payment arithmetic visible at the call site.
func addChecked(a, b int64) (int64, bool) {
	s := a + b
	if (b > 0 && s < a) || (b < 0 && s > a) {
		return 0, false
	}
	return s, true
}

func mulChecked(a, b int64) (int64, bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	p := a * b
	if p/b != a {
		return 0, false
	}
	return p, true
}

func padID(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// --- Render ---

// Render shows the catalog at "", a meter at "meter/<id>", an enrollment at
// "enroll/<id>". Every user string is sanitized; every list is bounded by
// RenderLimit with the bound stated.
func Render(path string) string {
	switch {
	case path == "":
		return renderHome()
	case hasPrefix(path, "meter/"):
		return renderMeter(path[len("meter/"):])
	case hasPrefix(path, "enroll/"):
		return renderEnrollment(path[len("enroll/"):])
	default:
		return "unknown path; try \"\", \"meter/<id>\" or \"enroll/<id>\"\n"
	}
}

func renderHome() string {
	out := "# meters — usage-based billing, graduated pricing\n\n"
	out += "Meters: " + itoa(nextMeter) + " · enrollments: " + itoa(nextEnr) +
		" · liabilities: " + itoa(ledger.Liabilities()) + Denom +
		" · fees accrued: " + itoa(ledger.FeesAccrued()) + Denom + "\n\n"
	out += "| id | title | unit | list price | period | status |\n|---|---|---|---|---|---|\n"
	// Newest-first, matching r/subscriptions: under oldest-first a squatter
	// retires 20 early meters once and owns the visible catalog forever;
	// newest-first makes that cost continuous re-creation. Audit finding Y2.
	shown := 0
	metersT.ReverseIterate("", "", func(_ string, v any) bool {
		m := v.(*meter)
		// TableCell, not InlineText: these strings sit between GFM pipes, and
		// InlineText deliberately leaves | literal -- a provider title with a
		// pipe would inject cells and spoof the price and status columns of
		// the one page a consumer reads before enrolling. Audit finding Y1.
		out += "| " + itoa(m.id) + " | " + sanitize.TableCell(m.title) + " | " +
			sanitize.TableCell(m.unit) + " | " + itoa(m.unitPrice) + Denom + " | " +
			itoa(m.periodBlocks) + " blocks | " + m.status + " |\n"
		shown++
		return shown >= RenderLimit
	})
	if nextMeter > int64(shown) {
		out += "\n(first " + itoa(int64(shown)) + " of " + itoa(nextMeter) + " meters)\n"
	}
	return out
}

func renderMeter(idStr string) string {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return "bad meter id\n"
	}
	v := metersT.Get(padID(id))
	if v == nil {
		return "unknown meter " + idStr + "\n"
	}
	m := v.(*meter)
	out := "# meter " + itoa(m.id) + " — " + sanitize.InlineText(m.title) + "\n\n"
	out += "- provider: " + m.provider.String() + "\n"
	out += "- unit: " + sanitize.InlineText(m.unit) + " at list " + itoa(m.unitPrice) + Denom + "\n"
	out += "- period: " + itoa(m.periodBlocks) + " blocks · fee: " + itoa(m.feeBps) + " bps · status: " + m.status + "\n"
	out += "- lifetime enrollments: " + itoa(m.enrollments) + "\n\n"
	out += "Schedule over the period base (units × list):\n\n| tier from (base " + Denom + ") | rate (/10000) |\n|---|---|\n"
	edges, rates := m.sched.Edges(), m.sched.Rates()
	lo := int64(0)
	for i, r := range rates {
		out += "| " + itoa(lo) + " | " + itoa(r) + " |\n"
		if i < len(edges) {
			lo = edges[i]
		}
	}
	return out
}

func renderEnrollment(idStr string) string {
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return "bad enrollment id\n"
	}
	v := enrollments.Get(padID(id))
	if v == nil {
		return "unknown enrollment " + idStr + "\n"
	}
	e := v.(*enrollment)
	pending := chargeFor(e, e.usage)
	out := "# enrollment " + itoa(e.id) + " (meter " + itoa(e.meterID) + ")\n\n"
	out += "- consumer: " + e.consumer.String() + "\n"
	out += "- provider: " + e.provider.String() + "\n"
	out += "- status: " + e.status + " · settled periods: " + itoa(e.periods) + "\n"
	out += "- period " + itoa(currentPeriod(e)) + " open; usage accumulator: " +
		itoa(e.usage) + " units in period " + itoa(e.usagePeriod) + "\n"
	out += "- balance: " + itoa(ledger.BalanceOf(enrollKey(e.id))) + Denom +
		" · pending charge: " + itoa(pending) + Denom + "\n"
	return out
}

func hasPrefix(s, p string) bool {
	return len(s) >= len(p) && s[:len(p)] == p
}
