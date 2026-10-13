// Package tiers prices one amount against a graduated schedule: cut the
// amount at caller-declared breakpoints, charge each slice at its own rate,
// and sum.
//
// This is the arithmetic behind a progressive fee, a marginal tax bracket, a
// volume discount and a tiered royalty. Nothing here reads the chain, holds
// state, or knows what the amount is a quantity of, so a realm can price a
// whole schedule without a node.
//
//	s, _ := New([]int64{1000, 5000}, []int64{100, 250, 500})
//	parts, err := s.SliceAt(7000)     // [1000 4000 2000] -- the partition
//	col, err := s.ChargeByTier(7000)  // [10 100 100]      -- the line items
//	fee, err := s.Charge(7000)        // 210               -- their sum
//
// The three steps are separable on purpose, in the shape [p/aging] uses: the
// partition is what a reader checks against the schedule, the per-tier column
// is the line items, and [Schedule.Charge] is the one number that goes in a
// ledger. Charge is *defined* as the sum of the column, so the two cannot
// disagree.
//
// # Marginal, and never a cliff
//
// Each slice of the amount is charged at the rate for the tier it falls in.
// The whole amount is never charged at the top tier's rate. Those are
// different numbers, and the difference is not a rounding matter: the cliff
// form has a discontinuity at every edge, where earning one more unit can
// cost more than one unit.
//
// With edges `{100}` and rates `{0, 5000}`, the cliff form charges 0 at 99 and
// 50 at 100 — one extra unit costs fifty. The graduated form charges 0 at 100
// and 0 at 101, because only the one unit above the edge is priced at 50%.
//
// What this package guarantees, at every amount and for every valid schedule:
//
//	Charge(n) <= Charge(n+1) <= Charge(n) + 1
//
// The left inequality is monotonicity; the right is the no-cliff property.
// Adding one unit to the amount grows exactly one slice by one, and
// `floor((x+1)r/RateScale) - floor(x·r/RateScale)` is 0 or 1 whenever
// `r <= RateScale`. [TestChargeHasNoCliffAtAnyEdge] asserts it at and around
// every edge of every schedule it builds, and [TestCliffFormulaViolatesIt]
// pins the counterexample so that a later "simplification" to the cliff form
// fails the suite instead of silently changing every published number.
//
// A third consequence of the same bound: `Charge(n) <= n`. A graduated
// schedule can never charge more than the amount it is pricing, which is what
// makes the rate cap in [New] an arithmetic fact and not only hygiene.
//
// # The amount is a length, and the half-open convention is load-bearing
//
// Think of the amount as the interval `[0, amount)`. Tier i covers the
// half-open range `[edges[i-1], edges[i])`, with tier 0 starting at 0 and the
// last tier unbounded above. That makes the tiers exhaustive and disjoint over
// every non-negative amount, with no breakpoint shared by two tiers. A slice
// is the overlap of `[0, amount)` with a tier's range, so the slices always
// sum to exactly the amount — [Schedule.SliceAt]'s cross-foot.
//
// The unit running from x to x+1 is priced at the tier containing **x**. So
// [Schedule.TierOf] and [Schedule.MarginalRate] answer a question about the
// *next* unit, not the last one:
//
//	MarginalRate(n) is the rate the (n+1)'th unit will attract.
//
// At an edge the two readings differ, and that difference is the off-by-one
// this package is most exposed to. With edges `{30}`, `MarginalRate(30)` is
// the *upper* tier's rate: the amount 30 exactly fills tier 0, and the next
// unit is the first one above the edge. The other reading — "the rate the last
// unit was charged at" — would answer with the lower tier, and is not offered,
// because it is undefined at amount 0.
//
// [p/aging] shipped an off-by-one of exactly this kind in its own discovery
// record (its doc, "The degenerate two-bucket case"), so the convention is
// stated here and pinned by [TestMarginalRateAtAnEdgeIsTheUpperTier] rather
// than left to a reader to reconstruct. [Schedule.TierRange] exists for the
// same reason: reconstructing a half-open range from [Schedule.Edges] is where
// the mistake lives.
//
// # Why the floor is taken per slice
//
//	Charge = Σ floor(sliceᵢ × rateᵢ / RateScale)
//
// not one floor taken at the end of an exact rational total. Those are
// different numbers, and which one a package shipped is invisible in any test
// that happens to use round rates.
//
// Per-slice is chosen because [Schedule.ChargeByTier] is the line-item column
// a reader sees next to the slices, and line items that do not add up to the
// stated total are a bookkeeping defect regardless of which total is "more
// accurate". The same discipline, and the same rationale, as [p/aging]'s
// per-bucket floor and [p/depreciation]'s `Charge`-from-`CarryingAt`.
//
// [TestFloorIsPerSliceNotAtTheEnd] pins a case where the two disagree.
//
// # Monotone in the amount — and why, unlike [p/aging], it really is
//
// [p/aging] published the analogous claim as settled and the code falsified
// it: its provision can **fall** as time advances, by up to one unit per
// bucket, because mass *moves between* buckets as an obligation ages and each
// bucket re-floors. Its doc records the counterexample and the attained bound.
//
// Here the claim holds, and the reason is structural rather than fortunate:
// increasing the amount only ever **adds mass at the top**. Every lower slice
// is already full, so its subtotal is literally the same number and no floored
// subtotal can shrink. Nothing moves between slices.
//
// That is an argument, so it is also measured: [TestChargeIsMonotone] sweeps
// random schedules across contiguous amounts and asserts a strictly
// non-decreasing charge. The discovery record for this package committed to
// amending itself rather than quietly editing if the sweep found a drop; the
// sweep found none, and the figure it ran is in the test rather than restated
// here.
//
// # Why the rates need NOT be monotone, which is the opposite of [p/aging]
//
// [New] accepts rates in any order. A rising schedule is a progressive fee; a
// falling one is a volume discount, which is the same arithmetic read from the
// other end and is a first-class use of this package, not a tolerated
// degenerate case.
//
// [p/aging] refuses a falling schedule, and the contrast is worth stating
// because copying that check here would be the plausible mistake. It needs the
// ordering for two reasons, neither of which transfers: a falling loss rate is
// a domain error (an older receivable is not more collectible), and without the
// ordering its exact-rational monotonicity fails as well, since an obligation
// crossing into a cheaper bucket *reduces* the total. In this package nothing
// crosses into anything. The monotonicity above needs only `rate >= 0`.
//
// So a transposed rate array is a silent authoring error here in a way it is
// not in [p/aging], and this package cannot detect it. That is recorded in
// "What this package does not claim" rather than papered over with a check
// that would also forbid every discount schedule.
//
// # The per-slice multiply goes through 128 bits
//
// `slice × rate` overflows an int64 for large amounts — a slice near maxInt64
// at any rate above 1 basis point — so the product is taken in 128 bits with
// `bits.Mul64` and divided with `bits.Div64`.
//
// The discipline is ADOPTED, not derived, and the source is [p/curve], read in
// full before this was written. Its guard carries the argument in its own
// comment: without the `hi < m` check, `bits.Div64` violates its own
// precondition and over-issues. See DISCOVERY.md § 3 and § 4, which attribute
// it.
//
// Here that precondition is *provable*: rates are capped at RateScale, so
// `slice × rate < 2^63 × 10^4 < 2^77` and `hi < 2^13 = 8192 < 10000 = m`.
// **It is checked anyway**, and so is the quotient's fit in an int64, which is
// provable from the same cap. A proof that rests on the rate cap is a proof
// that expires silently the day someone raises the cap, and CLAUDE.md § 7a's
// whole subject is checks that stop asking their question.
//
// Every guard in `chargeSlice` is therefore unreachable through the exported
// API, which makes them untestable through it. They are not left unexercised:
// `chargeSlice` is unexported and the suite calls it directly —
// [TestChargeSliceGuardsAPreconditionTheAPICannotReach] — so each guard has a
// test that fails when it is removed.
//
// No count is given here, deliberately. This paragraph said "Both guards" when
// it meant the two OVERFLOW guards specifically, and when the rate-sign guard
// was added the obvious repair — "three" — was wrong twice over: the function
// holds four guards, and two of the four are preconditions rather than overflow
// checks, so any single number here answers an ambiguous question. CLAUDE.md
// § 4a's rule applies — prefer deleting a restated number over updating it —
// and the sabotage harness counts them by construction anyway.
//
// An alternative was considered and
// rejected: binding the amount to `maxInt64/RateScale` so a plain int64
// multiply could not wrap. That bound is safe for any µGNOT quantity and is
// refused for exactly that reason — justifying it needs a unit, and this
// package declares it has none. See DISCOVERY.md § 4.
//
// The rate-sign guard was added after an adversarial audit, and the
// reason it was missing is worth more than the fix. The paragraph above proves
// the precondition from the rate *cap*, and a cap is an upper bound: writing it
// out established `rate <= RateScale` and said nothing about the other end,
// while the `slice < 0` guard sitting one line away made the function look as
// though both of its signed inputs had been considered. Measured, before the
// fix: `chargeSlice(1, -1)` returned `(1844674407370955, nil)` — a positive
// charge, a nil error, and both overflow guards cleanly passed, because
// `uint64(-1)` has a zero high word when multiplied by 1.
//
// What made it survive review is the near miss: `chargeSlice(maxInt64, -1)`
// *is* caught, by `hi >= m`, so the negative-rate family is half-covered by an
// existing check and a spot probe at the interesting end of int64 reports an
// error exactly as it should. The hole is at the *small* end, where nothing
// about the value looks extreme. A guard that catches the dramatic case and
// misses the mundane one reads, from the outside, like a guard that works.
//
// # What bounds the work
//
// Tier lookup is a linear scan over the edges, cheaper than a binary search at
// these sizes and the shape an auditor can check by reading. [MaxTiers] is 16,
// so there are at most 15 edges. One [Schedule.Charge] performs at most 16
// 128-bit multiplications and divisions over a 16-entry partition, and every
// exported method re-runs `check`, costing at most 50 further comparisons.
//
// That 50 is `2 + 2 + (MaxTiers-2) + 2×MaxTiers`, and the decomposition is
// pinned by [TestConstantsAreTheDocumentedValues] rather than left as a
// number in prose beside a constant nobody checked. This project has shipped
// that defect more than once.
//
// Those are the figures, not an assertion that they are affordable. A realm
// pricing many amounts in one transaction, or doing it inside a `Render`, must
// size them against the gas it has. This package bounds the work; it does not
// price it.
//
// # The one-tier schedule, and what it subsumes
//
// Empty edges are legitimate: `New(nil, []int64{250})` is a flat 2.5% on the
// whole amount, with one tier and no breakpoint. It is the degenerate case of
// the same formula rather than a special path.
//
// That schedule reproduces [p/nt/grc721/royalty]'s arithmetic — `salePrice *
// Bps / FeeDenominator` against the same 10000 denominator — with one
// difference in the implementation and none in the result for the amounts that
// package can take. Royalty multiplies before dividing in plain int64, so it is
// implicitly bounded at about `maxInt64/10000 ≈ 9.2e14`; this package's
// 128-bit path has no such bound. [TestOneTierSchedule] pins the agreement
// over the range where both are defined.
//
// [p/aging] is refused as a comparison in the other direction: it bins a *set*
// of items by each item's age, where this slices *one* amount by magnitude. A
// bin is not a slice, and the measurable consequence is the monotonicity
// section above. See DISCOVERY.md § 3.
//
// # What this package does not claim
//
//   - **No novelty for the formula.** A graduated rate schedule is textbook
//     arithmetic and three independent mul-div helpers already exist in the
//     ecosystem. What was not found in the searched sources is this shape:
//     a partition of one amount into magnitude slices at caller-declared
//     edges, each priced at its own rate. See DISCOVERY.md § 1 and § 3, which
//     also record a functionally exact mul-div primitive that was found,
//     classified reusable, and deliberately not imported.
//   - **No unit, deliberately.** The amount, the edges and the slices are
//     int64 in whatever unit the caller keeps consistently. A rate is
//     dimensionless. This is the stronger half of [p/aging]'s rule, and here
//     it costs nothing because there is no time axis to pick a convention for.
//   - **Nothing about money.** A charge is a number in a report. This package
//     never sees a coin, and a realm using it must not infer custody or a
//     transfer from it.
//   - **No opinion on where the edges and rates come from.** Picking them is
//     the whole of a fee policy and none of it is here. They are validated for
//     shape and range, never for plausibility — and, unlike [p/aging], not for
//     ordering either. A transposed rate array is accepted.
//   - **No schedule identity, and no versioning.** A [Schedule] is a value
//     with no name and no effective date. A realm that changes its fees must
//     keep its own record of which schedule priced which charge, because
//     nothing here can tell two schedules apart or say when one took effect.
//   - **Not a rounding policy.** The floor is the only rounding this package
//     performs and it is not configurable. A caller needing round-half-up, or
//     needing the exact rational, must compute it from [Schedule.SliceAt] and
//     the rates, both of which are exported for that purpose.
//
// [p/aging]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/aging
// [p/depreciation]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/depreciation
// [p/curve]: /p/g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6/curve/v0
// [p/nt/grc721/royalty]: /p/nt/grc721/royalty/v0
package tiers

import (
	"errors"
	"math/bits"
)

// RateScale is the denominator every rate is expressed against, so a rate is
// in basis points: 0 is 0%, 250 is 2.5%, 10000 is 100%.
//
// It is a constant rather than a per-schedule field on purpose, the same
// decision and the same reason as [p/aging]'s: a schedule carrying its own
// denominator lets two schedules in one realm be priced on different scales,
// and the first symptom of that is a charge wrong by a factor of a hundred
// with every individual number looking reasonable.
//
// The value is taken from the corpus rather than invented.
// [p/nt/grc721/royalty] declares it as the EIP-2981 basis-point denominator
// and `guildhall/trust/v0` independently ships the same ceiling; see
// DISCOVERY.md § 4.
const RateScale int64 = 10000

// MaxTiers bounds the number of tiers, and so bounds the edge scan in
// [Schedule.TierOf] and the loops in [Schedule.SliceAt] and
// [Schedule.ChargeByTier]. 16 is past the point where a tier is meaningful: a
// conventional fee schedule uses three or four.
//
// The minimum is 1, not 2, and that is the deliberate difference from
// [p/aging]'s MaxBuckets. A one-tier schedule has no edges and applies one
// rate to the whole amount, which is a flat fee — degenerate, but the same
// formula, and useful enough to be the subject of its own section in the
// package doc. [p/aging] refuses its own one-bucket case because a flat loss
// rate is not an aging schedule at all; a flat fee *is* a rate schedule.
//
// What the bound costs: a caller needing more than 16 tiers must compose two
// schedules, and the composition is **not** a 32-tier schedule. The second
// would restart its partition at 0, so every slice and every floor would be
// taken against the wrong origin. Composing graduated schedules is not
// supported and cannot be faked by addition.
const MaxTiers = 16

var (
	// ErrBadTierCount is returned when a schedule would have fewer than 1 or
	// more than MaxTiers tiers. The tier count is len(edges)+1, so this is a
	// statement about the edge slice: it must hold between 0 and MaxTiers-1
	// entries. A nil or empty edge slice is legitimate and does NOT land
	// here — it is the one-tier flat schedule.
	ErrBadTierCount = errors.New("tiers: tier count must be in [1, MaxTiers]")

	// ErrBadEdges is returned when the edges are not positive and strictly
	// increasing.
	//
	// Equal adjacent edges would define an empty tier, which is not an error
	// in arithmetic but is always an authoring mistake: it silently reduces
	// the schedule's resolution while every tier still reports.
	//
	// Positive and not merely non-negative, for the same reason one step
	// earlier. A first edge of 0 makes tier 0 the half-open range [0,0),
	// occupiable by nothing, for every amount, forever — while NumTiers still
	// reports it and its rate still prints. That is [p/aging]'s finding Y2,
	// which shipped as `< 0` and was corrected before deployment; the check
	// here reaches the first edge from the outset because of it.
	ErrBadEdges = errors.New("tiers: edges must be positive and strictly increasing")

	// ErrBadRateCount is returned when len(rates) != len(edges)+1. The
	// off-by-one here is the most likely way to build a wrong schedule that
	// still looks right, so it is named apart from ErrBadRate: a reader
	// seeing this error knows to count, not to look at values.
	ErrBadRateCount = errors.New("tiers: need exactly one rate per tier, which is len(edges)+1")

	// ErrBadRate is returned when a rate is negative or exceeds RateScale.
	//
	// The cap is arithmetic as well as hygiene. `rate <= RateScale` is what
	// makes `Charge(n) <= n`, what makes the no-cliff bound
	// `Charge(n+1) <= Charge(n)+1` hold, and what proves the 128-bit
	// precondition in chargeSlice. A rate above 100% would charge more than
	// the amount; a negative rate would charge a refund and would break the
	// monotonicity the package doc claims.
	//
	// The rates are NOT required to be ordered. See the package doc: a
	// falling schedule is a volume discount, and refusing it would be copying
	// a check from [p/aging] whose two reasons do not transfer.
	ErrBadRate = errors.New("tiers: each rate must be in [0, RateScale]")

	// ErrBadAmount is returned for a negative amount, and by the per-tier
	// accessors for a negative slice.
	//
	// Zero is legitimate, unlike [p/aging]'s obligation amount: an amount of
	// zero partitions into all-zero slices and charges 0, which is the right
	// answer and not a caller bug. A realm pricing an empty cart should not
	// have to special-case it.
	ErrBadAmount = errors.New("tiers: amount must not be negative")

	// ErrBadTierIndex is returned by the per-tier accessors for an index
	// outside [0, NumTiers).
	ErrBadTierIndex = errors.New("tiers: tier index out of range")

	// ErrOverflow is returned when the arithmetic would wrap.
	//
	// Through the exported API it is unreachable, and that is a claim with a
	// proof rather than an absence of evidence: the slices sum to the amount
	// and so each is at most maxInt64; every rate is at most RateScale; the
	// product is taken in 128 bits; and the quotient is at most the slice. The
	// guards in chargeSlice are kept anyway, because the proof rests entirely
	// on the rate cap and would expire silently if the cap were raised. See
	// the package doc, and TestChargeSliceGuardsAPreconditionTheAPICannotReach
	// for the direct unexported calls that do reach them.
	ErrOverflow = errors.New("tiers: int64 overflow")
)

// maxInt64 is written as a literal rather than as `int64(1)<<63 - 1`, which
// does not compile: the shift is evaluated in the already-typed int64 and
// overflows before the subtraction brings it back. The same note is in
// [p/aging] and [p/depreciation]; it is repeated because it is the same shape
// as the arithmetic this package exists to get right.
const maxInt64 int64 = 9223372036854775807

// Schedule is a graduated rate schedule: the amount breakpoints and the rate
// charged on each resulting slice.
//
// Its fields are unexported and the accessors copy, following [p/aging] and
// for the same reason: a schedule holding slices is not safely copyable, and a
// caller that kept the slice it passed to [New] could mutate the edges after
// validation so that every subsequent call priced against a schedule that
// never passed `check`. Construct with [New].
type Schedule struct {
	// edges holds the tier breakpoints, strictly increasing and positive.
	// Tier i is the half-open amount range [edges[i-1], edges[i]), with tier
	// 0 starting at 0 and the last tier unbounded above. It may be empty,
	// which is the one-tier flat schedule.
	edges []int64

	// rates holds one rate per tier in units of RateScale, each in
	// [0, RateScale] and in any order. len(rates) == len(edges)+1.
	rates []int64
}

// New validates and returns a schedule. The edges are the amount breakpoints,
// positive and strictly increasing; the rates are one per tier, so one more
// than there are edges, each in [0, RateScale].
//
//	New([]int64{1000, 5000}, []int64{100, 250, 500})
//
// reads as: 1% on the first 1000, 2.5% on the next 4000, 5% on everything
// above 5000.
//
// Empty edges are legitimate and give the one-tier flat schedule:
// `New(nil, []int64{250})` charges 2.5% of the whole amount. A first edge of 0
// is [ErrBadEdges] — it would define an empty tier 0.
//
// The rates are deliberately not required to be ordered; a falling schedule is
// a volume discount. See the package doc on why [p/aging] refuses what this
// accepts.
//
// Both slices are copied, so the caller may reuse or mutate its own.
func New(edges, rates []int64) (Schedule, error) {
	e := make([]int64, len(edges))
	copy(e, edges)
	r := make([]int64, len(rates))
	copy(r, rates)
	s := Schedule{edges: e, rates: r}
	if err := s.check(); err != nil {
		return Schedule{}, err
	}
	return s, nil
}

// check validates every field and establishes the precondition that lets
// chargeSlice divide without a guard per term.
//
// Every exported method that can return an error calls it rather than trusting
// its receiver, so the zero Schedule fails everywhere instead of pricing
// against nil slices.
//
// That qualifier is a correction. This said "Every exported method calls it",
// which is false: [Schedule.Edges] and [Schedule.Rates] do not, and cannot
// usefully — they return a slice and no error, so there is nothing for a failed
// check to become. An audit caught the overstatement, and the honest version of
// the invariant names where the protection actually lives:
//
//   - `edges` and `rates` are unexported, so no importer can build a Schedule
//     that did not come from [New].
//   - [New] rejects by returning `Schedule{}`, not the half-built `s`, so a
//     refused schedule carries no edges or rates to hand back. Measured: a
//     schedule New refused answers `Edges() == []`, `len 0`.
//
// So the two unchecked accessors are safe by CONSTRUCTION rather than by
// validation, and the distinction matters because the two fail differently. A
// check that is absent fails when someone adds a path around it; a field that
// is unexported fails only if someone exports it. Within this package the
// construction argument does not hold at all, and that is measurable rather
// than hypothetical: a hostile in-package struct literal answers
// `Edges() == [-5 -1]` while `Valid() == false`. Nothing is wrong with that
// today -- the package's own code never builds one -- but it is the state a
// future `New` variant that returned `s` beside its error would leak, and
// Edges/Rates are precisely the two methods that would not notice.
//
// Note
// what that costs here that it does not cost [p/aging]: the zero Schedule has
// no edges, which is a *legal* edge slice in this package, so it is the rate
// count that rejects it — `len(nil) != 0+1`. [ErrBadRateCount] is therefore
// the zero value's error, and TestZeroScheduleIsInvalid asserts exactly that
// rather than only that some error came back.
//
// The cost is at most 50 comparisons per call; see the package doc on bounds.
func (s Schedule) check() error {
	if len(s.edges) > MaxTiers-1 {
		return ErrBadTierCount
	}
	if len(s.rates) != len(s.edges)+1 {
		return ErrBadRateCount
	}
	// `<= 0` and not `< 0`, reaching the FIRST edge and not only the adjacent
	// pairs. Tier 0 is the half-open range [0, edges[0]), so an edges[0] of 0
	// makes it [0,0) — occupiable by nothing, forever — while NumTiers still
	// counts it and MarginalRate still returns its rate. That is precisely the
	// condition the loop below refuses between adjacent edges, and the first
	// edge is the one place the rule would not reach if it were written as a
	// pairwise loop alone. It is [p/aging]'s audit finding Y2, which is why it
	// is a separate statement with its own sabotage case.
	if len(s.edges) > 0 && s.edges[0] <= 0 {
		return ErrBadEdges
	}
	for i := 1; i < len(s.edges); i++ {
		if s.edges[i] <= s.edges[i-1] {
			return ErrBadEdges
		}
	}
	for _, rate := range s.rates {
		if rate < 0 || rate > RateScale {
			return ErrBadRate
		}
	}
	return nil
}

// Valid reports whether the schedule is well-formed. A zero Schedule is not.
func (s Schedule) Valid() bool { return s.check() == nil }

// NumTiers is the number of tiers, which is one more than the number of edges.
// It returns 0 for an invalid schedule, including the zero value, so a caller
// that skipped [Schedule.Valid] gets a number that reads as wrong rather than
// one that reads as a legitimate one-tier schedule.
//
// That distinction is sharper here than in [p/aging], where 0 could not be
// confused with anything: a one-tier schedule is valid in this package, so if
// NumTiers returned 1 for the zero value a caller could not tell the flat
// schedule from the broken one.
func (s Schedule) NumTiers() int {
	if s.check() != nil {
		return 0
	}
	return len(s.edges) + 1
}

// Edges returns a copy of the tier breakpoints. It is empty for a one-tier
// schedule.
func (s Schedule) Edges() []int64 {
	out := make([]int64, len(s.edges))
	copy(out, s.edges)
	return out
}

// Rates returns a copy of the per-tier rates, in units of [RateScale].
func (s Schedule) Rates() []int64 {
	out := make([]int64, len(s.rates))
	copy(out, s.rates)
	return out
}

// TierRange returns the half-open amount range of tier i as [lo, hi),
// together with whether it is unbounded above — which is true for the last
// tier and only the last tier, where hi is meaningless.
//
// It exists so that a caller rendering line items does not have to
// reconstruct the half-open convention from [Schedule.Edges]. That
// reconstruction is where an off-by-one lives, and [p/aging] shipped one of
// those in its own discovery record; see the package doc.
func (s Schedule) TierRange(i int) (lo, hi int64, unbounded bool, err error) {
	if err := s.check(); err != nil {
		return 0, 0, false, err
	}
	if i < 0 || i > len(s.edges) {
		return 0, 0, false, ErrBadTierIndex
	}
	if i > 0 {
		lo = s.edges[i-1]
	}
	if i == len(s.edges) {
		return lo, 0, true, nil
	}
	return lo, s.edges[i], false, nil
}

// TierOf returns the index of the tier that the NEXT unit of the amount falls
// in: 0 for the lowest, NumTiers-1 for the unbounded top.
//
// The partition is half-open, [lo, hi), which is what makes it exhaustive and
// disjoint over every non-negative amount with no breakpoint shared by two
// tiers. An amount equal to an edge is in the **upper** tier, so with edge
// 1000, `TierOf(1000)` is 1: the amount 1000 exactly fills tier 0 and the next
// unit is the first one above the breakpoint.
//
// Read it as a question about the next unit, never about the last one. See the
// package doc, which states the convention and names the off-by-one it avoids.
func (s Schedule) TierOf(amount int64) (int, error) {
	if err := s.check(); err != nil {
		return 0, err
	}
	if amount < 0 {
		return 0, ErrBadAmount
	}
	for i, edge := range s.edges {
		if amount < edge {
			return i, nil
		}
	}
	return len(s.edges), nil
}

// MarginalRate returns the rate the next unit of the amount will attract, in
// units of [RateScale]: the rate of [Schedule.TierOf]'s tier.
//
// It is not the average rate and not the rate the last unit was charged at.
// `MarginalRate(n)` prices unit n+1, so at an edge it returns the upper tier's
// rate; the package doc gives the reason the other reading is not offered.
//
// The effective rate on the whole amount is `Charge(n) × RateScale / n`, which
// is the caller's arithmetic: it needs a rounding decision this package does
// not make, and it is undefined at n = 0.
func (s Schedule) MarginalRate(amount int64) (int64, error) {
	i, err := s.TierOf(amount)
	if err != nil {
		return 0, err
	}
	return s.rates[i], nil
}

// SliceAt partitions an amount across the tiers and returns the slice in each,
// lowest first.
//
// The slices sum to exactly the amount — no remainder, no dust, by
// construction rather than by a correction step — because a slice is the
// overlap of `[0, amount)` with the tier's half-open range and the ranges
// partition `[0, ∞)`. [TestSliceAtCrossFoots] asserts the sum, and the package
// doc explains why that assertion alone is weak: moving mass between adjacent
// slices preserves it. Each edge comparison therefore has its own sabotage
// case, in tools/test_tiers_sabotage.sh.
//
// An amount of 0 returns all-zero slices and no error. Tiers above the amount
// are 0, which is why the result always has [Schedule.NumTiers] entries rather
// than being truncated at the last non-empty tier: a caller rendering line
// items against [Schedule.Rates] indexes both by tier.
func (s Schedule) SliceAt(amount int64) ([]int64, error) {
	if err := s.check(); err != nil {
		return nil, err
	}
	if amount < 0 {
		return nil, ErrBadAmount
	}
	out := make([]int64, len(s.edges)+1)
	for i := 0; i <= len(s.edges); i++ {
		var lo int64
		if i > 0 {
			lo = s.edges[i-1]
		}
		// The edges increase, so once the amount fails to reach this tier's
		// floor it reaches no higher tier either. The remaining entries stay
		// at their zero value, which is the correct answer and not an
		// omission.
		if amount <= lo {
			break
		}
		top := amount
		if i < len(s.edges) && s.edges[i] < amount {
			top = s.edges[i]
		}
		// No overflow is possible in either subtraction: lo is non-negative
		// and strictly below top in both branches, so the difference is a
		// positive int64.
		out[i] = top - lo
	}
	return out, nil
}

// ChargeByTier returns the charge on each slice of an amount, lowest first:
// the line-item column.
//
// Each entry is `floor(sliceᵢ × rateᵢ / RateScale)`, the floor taken per slice
// so that this column sums to exactly what [Schedule.Charge] reports. See the
// package doc for what that choice costs.
//
// Unlike [p/aging]'s ProvisionByBucket, this takes the amount rather than a
// caller-built report, so there is no cross-foot to validate and no way to
// price a partition that came from a different schedule. [p/aging] exports its
// Report so that a realm can accumulate buckets across calls, and pays for it
// with four validation branches and a documented hazard. Nothing here needs
// accumulation — one amount is one amount — so the opportunity is removed
// instead of guarded.
func (s Schedule) ChargeByTier(amount int64) ([]int64, error) {
	parts, err := s.SliceAt(amount)
	if err != nil {
		return nil, err
	}
	out := make([]int64, len(parts))
	for i, slice := range parts {
		c, err := chargeSlice(slice, s.rates[i])
		if err != nil {
			return nil, err
		}
		out[i] = c
	}
	return out, nil
}

// Charge returns the total charge on an amount: one number for a ledger.
//
// It is defined as the sum of [Schedule.ChargeByTier], so the single figure
// and the line items can never disagree — the same discipline [p/aging] uses
// for Provision and [p/depreciation] for Charge.
//
// The sum cannot overflow: each term is at most its slice, because every rate
// is at most RateScale, and the slices sum to the amount. That also gives
// `Charge(n) <= n`, stated in the package doc.
func (s Schedule) Charge(amount int64) (int64, error) {
	parts, err := s.ChargeByTier(amount)
	if err != nil {
		return 0, err
	}
	var sum int64
	for _, p := range parts {
		sum += p
	}
	return sum, nil
}

// chargeSlice returns floor(slice × rate / RateScale) with the product taken
// in 128 bits.
//
// It is unexported and it is called directly by the suite, which is the only
// way any guard below can be reached: every one of them is provably unreachable
// from a validated Schedule, and every one is kept. See the package doc, "The
// per-slice multiply goes through 128 bits", for the proof, the attribution to
// [p/curve], and why a proof resting on the rate cap is not treated as a
// licence to delete the check.
//
// "either guard … both" stood here until the Y1 fix added a fourth guard, and
// it was not caught by the sweep that fixed the other counts because a
// single-line grep does not match prose a comment wrap has split. Both of those
// failure modes are recorded in AUDIT.md § 5 item 1.
//
// Both signed inputs must be non-negative, and the callers establish each from
// a different place: `slice` from the partition [Schedule.SliceAt] builds, and
// `rate` from `check`, which rejects `rate < 0` before any Schedule exists.
// Naming only `slice` here is how the missing `rate < 0` guard went unnoticed
// — the doc described half the contract and the code enforced exactly as much
// as the doc described.
func chargeSlice(slice, rate int64) (int64, error) {
	if slice < 0 {
		return 0, ErrBadAmount
	}
	// Not symmetric with the guard above, and deliberately so: a negative slice
	// is a broken partition (ErrBadAmount), while a negative rate is a broken
	// schedule (ErrBadRate) — the error names which precondition failed, and
	// each is the error `check` would have returned for the same input.
	//
	// What it must precede is the DIVISION, not the conversion -- stated
	// precisely because the loose version of this sentence is the defect being
	// repaired. `uint64(rate)` is a value conversion and cannot fail, so a guard
	// sitting between it and `hi >= m` would behave identically; placing it
	// first is for the reader, not for correctness. What would be wrong is
	// placing it after the division, because `uint64(-1)` multiplied by a small
	// slice has a high word of zero, sails past `hi >= m`, and divides to a
	// large positive charge. Measured before this guard existed:
	// `chargeSlice(1, -1) = (1844674407370955, nil)`.
	if rate < 0 {
		return 0, ErrBadRate
	}
	m := uint64(RateScale)
	hi, lo := bits.Mul64(uint64(slice), uint64(rate))
	// bits.Div64 PANICS when its precondition hi < y is violated, so this is
	// not a politeness check: without it a wrapping input would abort the
	// transaction instead of returning an error, and the caller could not tell
	// an overflow from any other panic. The same argument [p/curve] makes in
	// its own comment.
	if hi >= m {
		return 0, ErrOverflow
	}
	q, _ := bits.Div64(hi, lo, m)
	// And the quotient must fit. Provable from rate <= RateScale, which gives
	// q <= slice <= maxInt64 — and checked for the same reason as above. The
	// two guards are not redundant: this one is reachable with a rate in
	// (RateScale, 2×RateScale), where the product's high word stays below m
	// but the quotient exceeds maxInt64.
	if q > uint64(maxInt64) {
		return 0, ErrOverflow
	}
	return int64(q), nil
}
