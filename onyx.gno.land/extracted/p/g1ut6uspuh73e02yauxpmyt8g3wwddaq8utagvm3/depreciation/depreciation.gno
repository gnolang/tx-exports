// Package depreciation is the carrying amount of a capital asset as a pure
// function of how many whole periods it has been in service.
//
// A realm stores the plan and the date the asset was placed in service, and
// asks this package what it is worth now and what to charge for the span
// since it last asked. Nothing here reads the chain, holds state, or knows
// what a ledger is, so a realm can test a decade of its own depreciation
// without a node.
//
//	s, err := New(120000, 0, 120)                 // 120000 over 120 months
//	n, _ := Periods(placedAt, now, Monthly)
//	charge, _ := s.Charge(booked, n)              // what to post
//	carrying, _ := s.CarryingAt(n)                // what it is worth
//
// # Why this is a function of n and not an accumulator
//
// The obvious implementation stores the carrying amount, subtracts a per-period
// charge, and advances an anchor to now. It is wrong in a way that is specific
// and quiet: the per-period charge is an integer division, so each call
// truncates, and the part-period the call lands in is forfeited. Run twice as
// often and you forfeit twice as much — which for an asset register means
// *running the schedule more often depreciates less*. That is a misstatement
// of asset value, not a rounding preference.
//
// [p/moul/x/games/accrual] names this bug and fixes it by advancing the anchor
// only by the whole periods it actually paid for, leaving the remainder on the
// clock, and it states the invariant that rules the bug out:
//
//	Advance(s, a, c) == Advance(Advance(s, a, b), b, c)   for a <= b <= c
//
// That invariant is adopted here, and the way it is obtained is different and
// stronger. Nothing in this package is an accumulator: [Schedule.CarryingAt]
// is a pure function of the period count, and [Schedule.Charge] is the
// difference of it at two points. So charges **telescope** —
//
//	Charge(a, b) + Charge(b, c) == Charge(a, c)
//
// — by construction rather than by careful anchor arithmetic, and there is no
// stored carrying amount that could drift from the schedule at all. A realm
// that loses track of what it has booked can recompute it from the dates.
// [TestChargesTelescope] asserts it over pseudo-random partitions, because an
// implementation that truncates per call passes every round span and fails
// only on the ones that land mid-period.
//
// The read path cannot disagree with the write path for the same reason: there
// is one function, and `Charge` is defined in terms of it.
//
// # Why a bounded loop is the right answer here and O(1) is not available
//
// accrual must be closed form because elapsed time is unbounded: the player
// who returns after a month is exactly the one whose Render times out.
// Depreciation has no such exposure, and declining balance has no integer
// closed form — period n is the rate applied n times, with the floor taken
// each period, and taking the floor once at the end is a different and wrong
// number.
//
// What bounds the loop instead is the asset's own **declared useful life**:
// [Schedule.CarryingAt] clamps at `Life` periods, `Life` is validated against
// [MaxLife] at construction, and the loop exits early once the salvage floor
// is reached. So the cost of a call is bounded by a number the caller declared
// and this package checked, not by how long ago the asset was bought. That is
// a different safety argument from closed-form and it is the one that makes
// declining balance implementable at all. Straight line *is* closed form and
// takes no loop.
//
// # What this package does not claim
//
//   - **No novelty for the straight-line arithmetic.** A quantity moving at a
//     fixed rate per period toward a bound is shipped elsewhere in this
//     ecosystem more than once; see DISCOVERY.md § 1. What was not found in the
//     searched sources is the domain model — a salvage floor, a carrying
//     amount, a declining-balance schedule over integers.
//   - **Nothing about money.** A carrying amount is a number in a plan. This
//     package never sees a coin, and a realm using it must not infer custody
//     from it.
//   - **No period convention beyond whole periods.** An asset placed in
//     service mid-period depreciates from its placed-in-service date, not from
//     the start of the calendar period it fell in. Half-year and mid-month
//     conventions are a caller's job: shift `placedAt`. See § 4 of AUDIT.md.
//   - **No switch to straight line.** Textbook declining balance often
//     crosses over to straight line once the latter charges more. This does
//     not; see [Schedule.CarryingAt] on what happens at `Life` instead.
//
// [p/moul/x/games/accrual]: /p/moul/x/games/accrual/v0
package depreciation

import "errors"

// MaxLife bounds the declared useful life in whole periods, and so bounds the
// declining-balance loop in [Schedule.CarryingAt]. 1200 is a century of
// monthly periods, which is past the point where any real schedule stops
// being meaningful.
//
// What the bound costs is stated here rather than waved at, because the
// earlier wording claimed the loop "is not a gas hazard even in a Render" and
// no gas was ever measured. The figures that were: CarryingAt runs the loop n
// times with n < Life, so at most MaxLife-1 = 1199 iterations per call, and
// [Schedule.Charge] evaluates CarryingAt twice, so one Charge can run 2398.
// The early exit at the salvage floor is an optimisation and not part of the
// bound — a schedule whose per-period charge truncates to zero
// (Cost*RateNum < RateDen) never moves off Cost, never reaches the floor, and
// so runs the full 1199 on every call for the asset's whole life. A realm
// that walks many assets in one transaction, or renders them, must size that
// against the gas it has. This package bounds the work; it does not price it.
const MaxLife = 1200

// Period lengths in seconds, for a caller that keeps time in unix seconds.
// They are conveniences and not a calendar: Monthly is 30 days and Yearly is
// 365, so neither tracks month lengths or leap years. A caller that needs a
// real calendar must compute its own period count and pass it to the
// CarryingAt/Charge pair directly, which take period counts and not times.
const (
	Daily   int64 = 86400
	Monthly int64 = 30 * Daily
	Yearly  int64 = 365 * Daily
)

var (
	// ErrBadCost is returned when cost is not positive. A zero-cost asset
	// has nothing to depreciate and makes Basis degenerate.
	ErrBadCost = errors.New("depreciation: cost must be positive")

	// ErrBadSalvage is returned when salvage is negative, or is not less
	// than cost. Salvage equal to cost is a non-depreciating asset, which
	// is legitimate bookkeeping but is not a schedule: there is no charge
	// to post, ever, and silently accepting it would have a realm open
	// accounts and post nothing.
	ErrBadSalvage = errors.New("depreciation: salvage must be in [0, cost)")

	// ErrBadLife is returned when the useful life is not positive or
	// exceeds MaxLife.
	ErrBadLife = errors.New("depreciation: life must be in [1, MaxLife]")

	// ErrBadMethod is returned for a method outside the declared set.
	ErrBadMethod = errors.New("depreciation: unknown method")

	// ErrBadRate is returned when a declining-balance factor is not a
	// proper fraction in (0, 1). A rate of 1 writes the asset off in one
	// period and a rate of 0 never charges anything; both are better said
	// another way, so neither is accepted here.
	ErrBadRate = errors.New("depreciation: rate must satisfy 0 < num < den")

	// ErrBadPeriod is returned when a period length is not positive.
	ErrBadPeriod = errors.New("depreciation: period must be positive")

	// ErrBackwards is returned when now falls before the placed-in-service
	// time. Time moving backwards is a caller bug — a stored timestamp from
	// another clock, a test that rewound — and treating it as zero elapsed
	// would hide it.
	ErrBackwards = errors.New("depreciation: now falls before placedAt")

	// ErrBadSpan is returned by Charge when the span runs backwards, which
	// would make a depreciation charge negative and credit an expense.
	ErrBadSpan = errors.New("depreciation: charge span must not run backwards")

	// ErrOverflow is returned when the arithmetic would wrap. Most
	// overflow is excluded at construction instead; see New.
	ErrOverflow = errors.New("depreciation: int64 overflow")
)

// The bounds are written as literals rather than as the usual `int64(1)<<63 - 1`
// idiom, which does not compile: the shift is evaluated in the already-typed
// int64 and overflows before the subtraction can bring it back in range. It is
// a compile error here rather than a wrong number, but it is the same shape as
// the arithmetic this package exists to get right, so it is worth naming.
const (
	maxInt64 int64 = 9223372036854775807
	maxInt32 int64 = 2147483647
)

// Method is how the basis is spread across the useful life.
type Method uint8

const (
	// StraightLine charges the basis evenly across the life. Closed form.
	StraightLine Method = 1

	// DecliningBalance charges a fixed fraction of the remaining carrying
	// amount each period, so early periods charge more. Not closed form
	// over integers; see the package doc on why the loop is bounded.
	DecliningBalance Method = 2
)

// Valid reports whether m is a method this package implements.
func (m Method) Valid() bool { return m == StraightLine || m == DecliningBalance }

// String names the method. The zero Method is "invalid" rather than empty, so
// a caller that renders it without checking Valid prints something that reads
// as wrong instead of something that reads as missing.
func (m Method) String() string {
	switch m {
	case StraightLine:
		return "straight-line"
	case DecliningBalance:
		return "declining-balance"
	}
	return "invalid"
}

// Schedule is the depreciation plan for one asset. It is a value, carries no
// state about what has been booked, and is safe to copy. Construct with
// [New] or [NewDeclining] so the invariants — including the overflow
// preconditions — are checked once rather than on every call.
type Schedule struct {
	// Cost is the depreciable basis at placed-in-service.
	Cost int64

	// Salvage is the floor. The carrying amount never falls below it and
	// reaches it exactly at Life.
	Salvage int64

	// Life is the useful life in whole periods.
	Life int32

	// Method is how the basis is spread.
	Method Method

	// RateNum and RateDen are the declining-balance factor as a proper
	// fraction. Both are zero for StraightLine.
	RateNum int64
	RateDen int64
}

// New validates and returns a straight-line schedule.
func New(cost, salvage int64, life int32) (Schedule, error) {
	s := Schedule{Cost: cost, Salvage: salvage, Life: life, Method: StraightLine}
	if err := s.check(); err != nil {
		return Schedule{}, err
	}
	return s, nil
}

// NewDeclining validates and returns a declining-balance schedule charging
// num/den of the remaining carrying amount each period. Double-declining over
// a 10-period life is num=2, den=10.
func NewDeclining(cost, salvage int64, life int32, num, den int64) (Schedule, error) {
	s := Schedule{
		Cost: cost, Salvage: salvage, Life: life,
		Method: DecliningBalance, RateNum: num, RateDen: den,
	}
	if err := s.check(); err != nil {
		return Schedule{}, err
	}
	return s, nil
}

// check validates every field and, critically, the two overflow
// preconditions. Establishing them here is what lets CarryingAt and Charge be
// total functions on a constructed Schedule: a zero value still fails, which
// is why every method calls check rather than trusting its receiver.
func (s Schedule) check() error {
	if s.Cost <= 0 {
		return ErrBadCost
	}
	if s.Salvage < 0 || s.Salvage >= s.Cost {
		return ErrBadSalvage
	}
	if s.Life <= 0 || int64(s.Life) > MaxLife {
		return ErrBadLife
	}
	if !s.Method.Valid() {
		return ErrBadMethod
	}
	switch s.Method {
	case StraightLine:
		// Basis*n is the only product, and n <= Life.
		if s.Basis() > maxInt64/int64(s.Life) {
			return ErrOverflow
		}
	case DecliningBalance:
		if s.RateDen <= 0 || s.RateNum <= 0 || s.RateNum >= s.RateDen {
			return ErrBadRate
		}
		// c*RateNum is the only product and c <= Cost, so Cost*RateDen
		// bounds it. Checking against RateDen rather than RateNum is
		// deliberate: it is the looser quantity, so the precondition
		// stays true if a later change moves the multiplication.
		if s.Cost > maxInt64/s.RateDen {
			return ErrOverflow
		}
	}
	return nil
}

// Valid reports whether the schedule is well-formed. A zero Schedule is not.
func (s Schedule) Valid() bool { return s.check() == nil }

// Basis is Cost - Salvage: the total that will ever be charged across the
// whole life, under either method.
//
// It does not validate, and it is the only exported method here that does
// not. That is forced rather than chosen: check() calls Basis to establish
// one of its own overflow preconditions, so Basis cannot call check(). It is
// therefore a bare subtraction over whatever fields it was handed, and on an
// ill-formed schedule it returns an arbitrary number — Schedule{Cost:
// maxInt64, Salvage: -1} wraps to minInt64. A zero result means "invalid, or
// zero cost", never "fully depreciated"; depreciation booked to date is
// [Schedule.AccumulatedAt], which does validate. Guard a caller-supplied
// schedule with [Schedule.Valid] before quoting Basis from it.
func (s Schedule) Basis() int64 { return s.Cost - s.Salvage }

// CarryingAt returns the carrying amount after n whole periods in service.
//
// It is monotone non-increasing in n, equals Cost at n <= 0, and equals
// Salvage exactly at every n >= Life. That last clamp is a declared
// convention and is doing real work under DecliningBalance, which approaches
// the floor asymptotically and would otherwise never reach it: the final
// period absorbs whatever remains. The consequence is worth stating because it
// is visible in the numbers — a declining-balance schedule's last charge can
// be much larger than the one before it. Textbooks usually avoid that by
// crossing over to straight line partway; this package does not, because the
// crossover rule is a policy choice that belongs to the caller and burying it
// here would make the schedule unexplainable from its own fields.
//
// A declining-balance schedule whose per-period charge truncates to zero
// never depreciates at all. The charge is (c*RateNum)/RateDen in integers, so
// whenever Cost*RateNum < RateDen it is 0, c never moves off Cost, and
// CarryingAt returns Cost at every n below Life and Salvage at Life — the
// whole of the basis falls in the last period. That is integer truncation
// behaving correctly and it is accepted rather than guarded, because the
// alternative is a minimum-charge rule, which is a policy a caller may
// reasonably want either way and cannot be inferred from the fields. It is
// documented because it is invisible in the ordinary numbers and is the one
// shape that also defeats the loop's early exit; see [MaxLife] on the cost.
//
// Under StraightLine the result is closed form. Under DecliningBalance it
// costs O(min(n, Life)) iterations, bounded by MaxLife and exiting early at
// the floor; see the package doc.
func (s Schedule) CarryingAt(n int32) (int64, error) {
	if err := s.check(); err != nil {
		return 0, err
	}
	if n <= 0 {
		return s.Cost, nil
	}
	if n >= s.Life {
		return s.Salvage, nil
	}
	if s.Method == StraightLine {
		// Basis*n cannot overflow: check() established
		// Basis <= maxInt64/Life and n < Life.
		return s.Cost - (s.Basis()*int64(n))/int64(s.Life), nil
	}
	c := s.Cost
	for i := int32(0); i < n; i++ {
		// c*RateNum cannot overflow: check() established
		// Cost <= maxInt64/RateDen, RateNum < RateDen, and c <= Cost.
		charge := (c * s.RateNum) / s.RateDen
		if c-charge < s.Salvage {
			charge = c - s.Salvage
		}
		c -= charge
		if c <= s.Salvage {
			return s.Salvage, nil
		}
	}
	return c, nil
}

// AccumulatedAt returns accumulated depreciation after n whole periods: the
// contra-asset balance, Cost - CarryingAt(n). It is defined in terms of
// CarryingAt so the two can never disagree, which is the same reason Charge
// is.
func (s Schedule) AccumulatedAt(n int32) (int64, error) {
	c, err := s.CarryingAt(n)
	if err != nil {
		return 0, err
	}
	return s.Cost - c, nil
}

// Charge returns the depreciation expense for moving a schedule from `from`
// whole periods booked to `to`.
//
// It is the difference of CarryingAt at the two points, which makes charges
// telescope exactly:
//
//	Charge(a, b) + Charge(b, c) == Charge(a, c)   for a <= b <= c
//
// So how often a realm runs the schedule cannot change the total it books, and
// a realm that has booked through period `from` can post Charge(from, now)
// with no stored carrying amount to drift. The result is never negative; a
// span that runs backwards is ErrBadSpan rather than a credit to an expense
// account.
func (s Schedule) Charge(from, to int32) (int64, error) {
	if err := s.check(); err != nil {
		return 0, err
	}
	if to < from {
		return 0, ErrBadSpan
	}
	before, err := s.CarryingAt(from)
	if err != nil {
		return 0, err
	}
	after, err := s.CarryingAt(to)
	if err != nil {
		return 0, err
	}
	// before >= after because CarryingAt is monotone non-increasing, so the
	// difference is non-negative and cannot overflow: both lie in
	// [Salvage, Cost].
	return before - after, nil
}

// Periods returns the whole periods elapsed between placedAt and now.
//
// A partial period in progress is not counted and is not lost: it is counted
// by a later call, once it completes. That is what makes the telescoping
// property above reach the right total however the caller slices time.
//
// The span is measured in uint64 on purpose, and the reason is the whole
// correctness argument. `now >= placedAt` is already enforced above, so the
// true elapsed span is non-negative; its largest value is
// maxInt64 - minInt64 = 2^64 - 1, which does not fit in an int64 and fits
// *exactly* in a uint64. int64 subtraction wraps two's-complement, so the bit
// pattern of now - placedAt is already the low 64 bits of the true difference,
// and reading that pattern as a uint64 recovers the difference with no loss,
// no clamp and no reachable wrap. ErrOverflow therefore means exactly one
// thing here — the quotient does not fit in an int32 — and the subtraction
// needs no guard at all.
//
// The guard it replaces, `placedAt < 0 && now > 0 && elapsed < 0`, was wrong
// in *both* directions, measured by exhaustive differential sweep against
// exact arithmetic rather than reasoned about: it returned (0, nil) for
// Periods(minInt64, 0, 1) and even a negative count for
// Periods(minInt64, 0, 2^62), and it rejected representable answers such as
// Periods(-1, maxInt64, maxInt64), whose count is 1. See § 5 of AUDIT.md.
func Periods(placedAt, now, period int64) (int32, error) {
	if period <= 0 {
		return 0, ErrBadPeriod
	}
	if now < placedAt {
		return 0, ErrBackwards
	}
	n := (uint64(now) - uint64(placedAt)) / uint64(period)
	if n > uint64(maxInt32) {
		return 0, ErrOverflow
	}
	return int32(n), nil
}

// FullyDepreciatedAt returns the time at which the asset first carries only
// its salvage value, for a realm that wants to tell a reader when the charges
// stop. It is placedAt + Life*period.
//
// Under DecliningBalance the carrying amount may sit very close to salvage
// well before this time, and under both methods it is not at salvage until
// this time, because Life is what the clamp in CarryingAt uses.
func (s Schedule) FullyDepreciatedAt(placedAt, period int64) (int64, error) {
	if err := s.check(); err != nil {
		return 0, err
	}
	if period <= 0 {
		return 0, ErrBadPeriod
	}
	if int64(s.Life) > maxInt64/period {
		return 0, ErrOverflow
	}
	span := int64(s.Life) * period
	if placedAt > maxInt64-span {
		return 0, ErrOverflow
	}
	return placedAt + span, nil
}
