// Package aging partitions a set of unpaid obligations by how long each has
// been past due, and prices the resulting schedule into a single expected
// loss.
//
// A realm holds the obligations — invoices, loans, dues — and asks this
// package two questions: how is what I am owed distributed across age bands,
// and what should I expect not to collect. Nothing here reads the chain, holds
// state, or knows what an invoice is, so a realm can test a year of its own
// receivables without a node.
//
//	s, _ := New([]int64{30, 60, 90}, []int64{0, 1000, 2500, 5000})
//	rep, err := s.ReportAt(obs, now)   // four bucket totals and their sum
//	loss, err := s.Provision(rep)      // the expected credit loss
//
// The two steps are separable on purpose: the report is the line items a
// reader sees, and the provision is the one number that goes in a ledger.
// [Schedule.ProvisionFor] does both in one call for a caller that only wants
// the number.
//
// # The output is a provision, and never an allowance
//
// The textbook name for this number is "allowance for doubtful accounts", and
// that word is not available here. `allowance` already means a *spending*
// allowance across this portfolio — including [p/spendbook]'s `Allowance`
// type — and it means an approve/transferFrom quota across the wider
// ecosystem's GRC20 realms. A type named `Allowance` in a package imported
// beside either of those would read as the wrong thing at every call site, so
// the loss number is `Provision` throughout. See DISCOVERY.md § 4.
//
// # Why the floor is taken per bucket, and exactly what that costs
//
// The provision is the sum of per-bucket floors:
//
//	Provision = Σ floor(bucketᵢ × rateᵢ / RateScale)
//
// not one floor taken at the end of an exact rational total. Those are
// different numbers, and which one a package shipped is invisible in any test
// that happens to use round rates.
//
// Per-bucket is chosen because [Schedule.ProvisionByBucket] is the line-item
// column a reader sees next to the bucket totals, and line items that do not
// add up to the stated total are a bookkeeping defect regardless of which
// total is "more accurate". [Schedule.Provision] is *defined* as the sum of
// that column, so the two cannot disagree — the same discipline
// [p/depreciation] uses to define `Charge` in terms of `CarryingAt`.
//
// The cost of that choice is a real and measurable weakening of the obvious
// invariant, and it is stated here because the discovery record for this
// package asserted the strong form and the strong form is false:
//
//	FALSE: for a fixed unpaid set, Provision is non-decreasing in now.
//
// The counterexample is small enough to state in full. Take edges `[30]` and
// rates `[5000, 5000]` — one boundary, the same 50% either side — and two
// obligations of amount 1. While both sit in bucket 0 the buckets are
// `[2, 0]` and the provision is `floor(2×5000/10000) = 1`. Let one age past
// 30: the buckets become `[1, 1]`, each floors to `0`, and the provision is
// `0`. **It fell as the receivables got older**, with no payment and no change
// of rate. One floor at the end would have returned 1 in both states.
//
// What is true, and what [TestProvisionNearlyMonotone] asserts:
//
//   - The exact rational provision Σ bucketᵢ×rateᵢ/RateScale **is**
//     non-decreasing in `now`, because an obligation only ever moves to a
//     higher-indexed bucket and [New] requires the rates to be
//     non-decreasing. That is the economic claim, and it survives.
//   - The integer provision is non-decreasing **to within fewer than
//     NumBuckets units**: each bucket loses strictly less than 1 to its
//     floor, and only a non-empty bucket loses anything, so
//     `Provision(later) > Provision(earlier) - min(NumBuckets, len(obs))`.
//     That bound is **attained**, not merely sound, and the figure is left
//     to [TestTheMonotonicityBoundIsAttained] rather than restated here:
//     at a flat rate of `RateScale-1`, `n` obligations of amount 1 price to
//     `n-1` when they share a bucket and to 0 when they are one per bucket,
//     so the drop is exactly `min(NumBuckets, len(obs)) - 1` at every
//     bucket count this package allows. No slack is available to an
//     implementation that wanted some.
//
// The random sweep in [TestProvisionNearlyMonotone] reports a far smaller
// largest drop than that, and the difference is a property of the sweep
// rather than of the package: with randomly drawn rates the shape that loses
// the most to the floors essentially never comes up. Both run, and the
// constructed one is the one the bound is quoted from.
//
// So the provision is safe to re-run and safe to re-run often — it cannot
// wander upward, and it cannot fall by more than a rounding unit per bucket.
// It is not a monotone function, and a realm that gates on
// `provision >= lastProvision` will eventually be wrong by one. [TestFloorIsPerBucketNotAtTheEnd]
// pins the counterexample itself, so a later "fix" that quietly moves to a
// single floor at the end fails the suite rather than silently changing every
// published number.
//
// # Why the rates must be non-decreasing
//
// [New] refuses a rate schedule that falls anywhere. Two reasons, and the
// second is the load-bearing one:
//
//   - It is the domain claim. An older receivable is not more likely to be
//     collected than a younger one. A schedule that says otherwise is almost
//     always a transposed array, which is a real and silent authoring error:
//     `{5000, 2500, 1000, 0}` is a plausible-looking argument and prices a
//     portfolio inside-out.
//   - Without it the *exact rational* monotonicity above fails too, and then
//     nothing is left. An obligation crossing an edge into a cheaper bucket
//     reduces the exact provision, so the only invariant this package offers
//     would be false in its strong form as well as its integer form.
//
// # Why a not-yet-due obligation is refused
//
// An obligation with `DueAt > now` has no age, and the choices are to refuse
// it or to put it in the youngest bucket. Bucketing it would be silent and
// would inflate every provision by whatever the youngest rate is applied to
// money that nobody is late paying. So it is [ErrNotYetDue], following
// `r/books`' `TestKindOfReportsInvalidRatherThanBucketing` — refused, not
// silently bucketed.
//
// The "current" column of a conventional aging report is therefore the
// caller's, and the caller already has it: on [r/invoices] it is
// `OutstandingFrom - OverdueFrom`. This package describes the past-due tail
// and declines to guess about the rest.
//
// # The degenerate two-bucket case, and the off-by-one in it
//
// A two-bucket schedule with edge `1` and rates `{0, RateScale}` reproduces
// [r/invoices]' `OverdueFrom` exactly, over the obligations whose `DueAt` has
// arrived: everything strictly past due is priced at 100% and everything else
// at 0%.
//
// The edge is **1 and not 0**, which is worth the sentence because
// DISCOVERY.md § 1 says 0 and is wrong. `isOverdue` is `now > dueHeight`,
// strictly — an invoice at exactly its due height is due and not yet late, so
// that invoice has age 0 and must land in the *unpriced* bucket. Edge 0 makes
// bucket 0 empty and prices it at 100%, overstating the loss by every invoice
// due precisely today. An off-by-one on a half-open boundary is the defect
// class this package is most exposed to, and the discovery record shipped one
// in the very claim that identified the consumer.
//
// Edge 0 is now refused outright — [ErrBadEdges], see check — so the
// overstatement described above is no longer expressible rather than merely
// documented. It was expressible, and accepted, until the pre-deployment audit
// found it: AUDIT.md Y2. A paragraph naming a defect class while the validator
// admitted an instance of it is the shape worth remembering here.
//
// Note also what an `Amount` is in that correspondence: `OverdueFrom` sums
// `amount - paid`, the unpaid remainder. [Obligation.Amount] is that
// remainder and not a face amount. A caller that passes face amounts prices
// money it has already collected.
//
// # What bounds the work
//
// Bucket lookup is a linear scan over the edges, which is cheaper than a
// binary search at these sizes and is the shape an auditor can check by
// reading. [MaxBuckets] is 16, so there are at most 15 edges, and
// [MaxObligations] is 1024: one [Schedule.ReportAt] therefore performs at
// most 15,360 comparisons plus 1024 additions, and [Schedule.Provision]
// performs at most 16 multiplications and divisions. Every exported method
// re-runs `check`, which costs at most 31 further comparisons.
//
// Those are the figures, not an assertion that they are affordable. A realm
// that ages several portfolios in one transaction, or does it inside a
// `Render`, must size them against the gas it has. This package bounds the
// work; it does not price it.
//
// # What this package does not claim
//
//   - **No novelty for partitioning time into buckets.** [p/twap] on
//     gnoland-1 quantises an observation series into fixed-width windows and
//     was read in full before this was written; what was not found in the
//     searched sources is the domain model — obligations, a past-due age, a
//     per-band loss rate, a provision. See DISCOVERY.md § 1 and § 3.
//   - **Nothing about money.** A provision is an estimate in a report. This
//     package never sees a coin, and a realm using it must not infer custody
//     or a transfer from it.
//   - **No unit of time, deliberately.** `DueAt`, `now` and the edges are
//     int64 in whatever unit the caller keeps consistently — block heights or
//     unix seconds. The rule and its rationale are adopted from
//     [p/moul/x/games/accrual]: prefer a timestamp, because a height-indexed
//     band drifts in wall-clock terms every time the chain's block time
//     moves. "30 days" is the caller's arithmetic, not a constant here. See
//     DISCOVERY.md § 4, which attributes the decision.
//   - **No opinion on where the rates come from.** Picking loss rates is the
//     whole of credit policy and none of it is in this package. The rates are
//     an input, validated for shape and ordering and never for plausibility.
//   - **No write-off, no recovery, no roll-forward.** A provision is a point
//     estimate from one snapshot. Moving a receivable out of the pool, and
//     reversing it when a payment arrives late, are a realm's job because
//     both are state changes and nothing here holds state.
//
// [p/spendbook]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/spendbook
// [p/depreciation]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/depreciation
// [r/invoices]: /r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/invoices
// [p/twap]: /p/moul/x/twap/v0
// [p/moul/x/games/accrual]: /p/moul/x/games/accrual/v0
package aging

import "errors"

// RateScale is the denominator every loss rate is expressed against, so a
// rate is in basis points: 0 is 0%, 2500 is 25%, 10000 is 100%.
//
// It is a constant rather than a per-schedule field on purpose. A schedule
// carrying its own denominator lets two schedules in one realm be priced on
// different scales, and the first symptom of that is a provision wrong by a
// factor of a hundred with every individual number looking reasonable.
const RateScale int64 = 10000

// MaxBuckets bounds the number of age bands, and so bounds the edge scan in
// [Schedule.BucketOf] and the loops in [Schedule.ReportAt] and
// [Schedule.Provision]. 16 is past the point where a band is meaningful: a
// conventional aging report uses four or five.
//
// The minimum is 2, and that is a refusal rather than an omission. A
// one-bucket schedule has no edges, applies one rate to the whole balance,
// and is a flat-rate provision rather than an aging schedule — legitimate
// arithmetic, better said as `floor(total * rate / RateScale)` at the call
// site, where a reader can see that no aging happened.
const MaxBuckets = 16

// MaxObligations bounds how many obligations one [Schedule.ReportAt] call
// will accept, following [p/lots]' own 1024 and for the same reason: the
// caller's slice length is the only thing that bounds the loop, and an
// unbounded loop over caller-supplied data is a gas hazard a realm cannot
// size in advance.
//
// What the bound costs: a realm with more than 1024 open obligations must
// report in chunks and add the provisions, and that sum is **not** the
// provision of the whole. Each chunk floors its own buckets, so chunking
// loses up to one unit per bucket per chunk — the same effect the package doc
// bounds for the clock, arriving by a different route. A realm that needs the
// exact figure over a larger pool must accumulate the bucket totals itself
// and call [Schedule.Provision] once on the combined report, which is
// supported: `Provision` takes a [Report] and does not care where it came
// from.
//
// [p/lots]: /p/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/lots
const MaxObligations = 1024

var (
	// ErrBadBucketCount is returned when a schedule would have fewer than 2
	// or more than MaxBuckets buckets. The bucket count is len(edges)+1, so
	// this is a statement about the edge slice: it must hold between 1 and
	// MaxBuckets-1 entries. A nil or empty edge slice lands here, which is
	// what makes the zero Schedule invalid.
	ErrBadBucketCount = errors.New("aging: bucket count must be in [2, MaxBuckets]")

	// ErrBadEdges is returned when the edges are not positive and strictly
	// increasing. Equal adjacent edges would define an empty bucket, which
	// is not an error in arithmetic but is always an authoring mistake: it
	// silently reduces the schedule's resolution while every bucket total
	// still reports.
	//
	// Positive and not merely non-negative, for the same reason one step
	// earlier: a first edge of 0 makes bucket 0 the empty range [0,0). The
	// rationale here is the whole of the argument for refusing it, which is
	// why the check now reaches the first edge too; see check.
	ErrBadEdges = errors.New("aging: edges must be positive and strictly increasing")

	// ErrBadRateCount is returned when len(rates) != len(edges)+1. The
	// off-by-one here is the most likely way to build a wrong schedule that
	// still looks right, so it is named apart from ErrBadRate: a reader
	// seeing this error knows to count, not to look at values.
	ErrBadRateCount = errors.New("aging: need exactly one rate per bucket, which is len(edges)+1")

	// ErrBadRate is returned when a rate is negative or exceeds RateScale.
	// A rate above 100% would provision more than is owed; a negative rate
	// would provision a gain.
	ErrBadRate = errors.New("aging: each rate must be in [0, RateScale]")

	// ErrRatesDecrease is returned when the rates fall anywhere across the
	// buckets. See the package doc: it is both the domain claim and the
	// precondition for the only monotonicity this package offers.
	ErrRatesDecrease = errors.New("aging: rates must not decrease as buckets age")

	// ErrNotYetDue is returned for an obligation whose DueAt has not
	// arrived, and by BucketOf for a negative age — which is the same
	// condition expressed in age terms. Refused rather than bucketed; see
	// the package doc.
	ErrNotYetDue = errors.New("aging: obligation is not yet due and has no age")

	// ErrBadAmount is returned for an obligation amount that is not
	// positive. Zero is refused as well as negative: a zero obligation
	// consumes one of the MaxObligations slots and changes nothing, so it
	// is a caller bug worth surfacing rather than a free no-op.
	ErrBadAmount = errors.New("aging: obligation amount must be positive")

	// ErrTooManyObligations is returned when more than MaxObligations are
	// passed in one call. See MaxObligations on chunking, and on why the
	// chunked sum is not the same number.
	ErrTooManyObligations = errors.New("aging: more than MaxObligations in one report")

	// ErrBadReport is returned by Provision when a report's bucket count
	// does not match the schedule's. It is the only structural check
	// available: a Report carries no identity, so two schedules with the
	// same bucket count accept each other's reports. A Report must
	// therefore not outlive the Schedule that produced it; prefer
	// ProvisionFor, which makes that impossible.
	ErrBadReport = errors.New("aging: report bucket count does not match the schedule")

	// ErrCrossFoot is returned by Provision when a report's bucket totals
	// do not sum to its stated Total. Reports built by ReportAt always
	// cross-foot by construction, so this fires only for a caller-built or
	// mutated Report — which is exactly why it is an error here and not
	// merely an assertion in the test suite.
	ErrCrossFoot = errors.New("aging: report buckets do not sum to its total")

	// ErrBadBucketIndex is returned by the per-bucket accessors for an
	// index outside [0, NumBuckets).
	ErrBadBucketIndex = errors.New("aging: bucket index out of range")

	// ErrOverflow is returned when the arithmetic would wrap: an age that
	// does not fit in an int64, a bucket total or report total that exceeds
	// what can be priced at RateScale, or a sum of amounts that does not
	// fit. Every other overflow is excluded by the construction-time
	// checks; see check.
	//
	// The pricing bound is enforced in both places it is reachable, which is
	// deliberate and not redundant: ReportAt bounds the running total so
	// that a report it returns can always be priced, and ProvisionByBucket
	// bounds each bucket because it also accepts caller-built reports it
	// never produced. Dropping either one is a reachable defect, and each
	// has its own sabotage case.
	ErrOverflow = errors.New("aging: int64 overflow")
)

// maxInt64 is written as a literal rather than as `int64(1)<<63 - 1`, which
// does not compile: the shift is evaluated in the already-typed int64 and
// overflows before the subtraction brings it back. The same note is in
// [p/depreciation]; it is repeated because it is the same shape as the
// arithmetic this package exists to get right.
const maxInt64 int64 = 9223372036854775807

// Obligation is one thing owed, as the pair this package needs: how much is
// still unpaid and when it fell due.
//
// Amount is the unpaid remainder, not a face amount — on [r/invoices] that is
// `amount - paid`. DueAt is in the caller's time unit, consistently with the
// `now` passed to [Schedule.ReportAt] and with the schedule's edges.
//
// It is a value and carries no identity. This package cannot tell two
// obligations apart and does not try: the same obligation passed twice is
// counted twice, and deduplication is the caller's, because only the caller
// knows what makes one of its receivables the same as another.
type Obligation struct {
	Amount int64
	DueAt  int64
}

// Report is one aging snapshot: the unpaid total in each bucket, youngest
// first, and their sum.
//
// Its fields are exported so a caller can render the line items, and so a
// realm can accumulate buckets across several [Schedule.ReportAt] calls and
// price them in one go — see [MaxObligations]. The cost of exporting them is
// that a Report can be built or mutated into something inconsistent, which is
// why [Schedule.Provision] re-derives nothing and instead validates: bucket
// count against the schedule, each bucket non-negative, and the cross-foot.
//
// A Report carries no reference to the Schedule that made it. Two schedules
// with the same bucket count will accept each other's reports and silently
// price them on the wrong rates, so a Report must not outlive its Schedule.
// [Schedule.ProvisionFor] exists to remove the opportunity.
type Report struct {
	// Buckets holds the unpaid total per bucket, index 0 being the
	// youngest. Its length is the schedule's NumBuckets.
	Buckets []int64

	// Total is the sum of Buckets. It is stored rather than recomputed so
	// that Provision has something to cross-foot against.
	Total int64
}

// Schedule is an aging schedule: the age boundaries and the loss rate for
// each resulting band.
//
// Its fields are unexported and the accessors copy, which is a deliberate
// departure from [p/depreciation]'s all-scalar exported Schedule. A schedule
// holding slices is not safely copyable: a caller that kept the slice it
// passed to [New] could mutate the edges after validation and every
// subsequent call would price against a schedule that never passed `check`.
// Construct with [New].
type Schedule struct {
	// edges holds the bucket boundaries, strictly increasing and
	// non-negative. Bucket i is the half-open age range
	// [edges[i-1], edges[i]), with bucket 0 starting at 0 and the last
	// bucket unbounded above.
	edges []int64

	// rates holds one loss rate per bucket in units of RateScale,
	// non-decreasing. len(rates) == len(edges)+1.
	rates []int64
}

// New validates and returns a schedule. The edges are the age boundaries,
// positive and strictly increasing; the rates are one per bucket, so one
// more than there are edges, each in [0, RateScale] and non-decreasing.
//
// Positive, so the smallest legal first edge is 1 and the smallest legal
// schedule is `New([]int64{1}, []int64{0, RateScale})` — which is exactly the
// degenerate strictly-overdue schedule the package doc describes. A first edge
// of 0 is [ErrBadEdges]: it would define an empty bucket 0.
//
//	New([]int64{30, 60, 90}, []int64{0, 1000, 2500, 5000})
//
// reads as: nothing provisioned under 30 past due, 10% from 30 to 59, 25%
// from 60 to 89, 50% from 90 on.
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

// check validates every field and establishes the overflow precondition that
// lets [Schedule.Provision] multiply without a guard per term.
//
// Every exported method calls it rather than trusting its receiver, so the
// zero Schedule fails everywhere instead of pricing against nil slices. The
// cost is at most 31 comparisons per call; see the package doc on bounds.
func (s Schedule) check() error {
	if len(s.edges) < 1 || len(s.edges) > MaxBuckets-1 {
		return ErrBadBucketCount
	}
	if len(s.rates) != len(s.edges)+1 {
		return ErrBadRateCount
	}
	// `<= 0` and not `< 0`. Bucket 0 is the half-open range [0, edges[0]), so
	// an edges[0] of 0 makes it [0,0) — occupiable by nothing, for every input,
	// forever — while NumBuckets still reports it and every bucket total still
	// prints. That is precisely the condition ErrBadEdges refuses between
	// adjacent edges, and the first edge was the one place the rule did not
	// reach. Shipped as `< 0` and corrected before deployment; the measurement
	// and the audit finding are in AUDIT.md Y2.
	if s.edges[0] <= 0 {
		return ErrBadEdges
	}
	for i := 1; i < len(s.edges); i++ {
		if s.edges[i] <= s.edges[i-1] {
			return ErrBadEdges
		}
	}
	for i, rate := range s.rates {
		if rate < 0 || rate > RateScale {
			return ErrBadRate
		}
		if i > 0 && rate < s.rates[i-1] {
			return ErrRatesDecrease
		}
	}
	return nil
}

// Valid reports whether the schedule is well-formed. A zero Schedule is not.
func (s Schedule) Valid() bool { return s.check() == nil }

// NumBuckets is the number of age bands, which is one more than the number of
// edges. It returns 0 for an invalid schedule, including the zero value, so a
// caller that skipped [Schedule.Valid] gets a number that reads as wrong
// rather than one that reads as a one-bucket schedule.
func (s Schedule) NumBuckets() int {
	if s.check() != nil {
		return 0
	}
	return len(s.edges) + 1
}

// Edges returns a copy of the bucket boundaries.
func (s Schedule) Edges() []int64 {
	out := make([]int64, len(s.edges))
	copy(out, s.edges)
	return out
}

// Rates returns a copy of the per-bucket loss rates, in units of [RateScale].
func (s Schedule) Rates() []int64 {
	out := make([]int64, len(s.rates))
	copy(out, s.rates)
	return out
}

// BucketRange returns the half-open age range of bucket i as
// [lo, hi), together with whether it is unbounded above — which is true for
// the last bucket and only the last bucket, where hi is meaningless.
//
// It exists so that a caller rendering line items does not have to
// reconstruct the half-open convention from [Schedule.Edges]. That
// reconstruction is where an off-by-one lives, and this package has already
// shipped one of those in its own discovery record; see the package doc.
func (s Schedule) BucketRange(i int) (lo, hi int64, unbounded bool, err error) {
	if err := s.check(); err != nil {
		return 0, 0, false, err
	}
	if i < 0 || i > len(s.edges) {
		return 0, 0, false, ErrBadBucketIndex
	}
	if i > 0 {
		lo = s.edges[i-1]
	}
	if i == len(s.edges) {
		return lo, 0, true, nil
	}
	return lo, s.edges[i], false, nil
}

// Age returns how long an obligation has been due: now - dueAt.
//
// Zero is a legitimate age and means "due exactly now, not yet late". A
// `dueAt` in the future is [ErrNotYetDue] rather than a negative age; see the
// package doc on why it is refused rather than bucketed.
//
// The span is measured in uint64 and the reason is the whole correctness
// argument, adopted verbatim from [p/depreciation]'s `Periods`. `now >= dueAt`
// is enforced first, so the true difference is non-negative; its largest
// value is maxInt64 - minInt64 = 2^64 - 1, which does not fit in an int64 and
// fits exactly in a uint64. int64 subtraction wraps two's-complement, so the
// bit pattern of now - dueAt is already the low 64 bits of the true
// difference, and reading it as a uint64 recovers that difference with no
// loss and no reachable wrap. [ErrOverflow] therefore means exactly one thing
// here — the true age exceeds maxInt64 — and the subtraction needs no guard.
func Age(dueAt, now int64) (int64, error) {
	if now < dueAt {
		return 0, ErrNotYetDue
	}
	span := uint64(now) - uint64(dueAt)
	if span > uint64(maxInt64) {
		return 0, ErrOverflow
	}
	return int64(span), nil
}

// BucketOf returns the index of the bucket an age falls in: 0 for the
// youngest, NumBuckets-1 for the unbounded oldest.
//
// The partition is half-open, [lo, hi), which is what makes it exhaustive and
// disjoint over every non-negative age with no boundary shared by two
// buckets. An age equal to an edge belongs to the **older** bucket, so edge
// 30 means "30 and over is in the next band".
//
// A negative age is [ErrNotYetDue], the same error [Age] returns for the same
// condition.
func (s Schedule) BucketOf(age int64) (int, error) {
	if err := s.check(); err != nil {
		return 0, err
	}
	if age < 0 {
		return 0, ErrNotYetDue
	}
	for i, edge := range s.edges {
		if age < edge {
			return i, nil
		}
	}
	return len(s.edges), nil
}

// ReportAt partitions the obligations by age at time `now` and returns the
// per-bucket unpaid totals and their sum.
//
// Every obligation must be due — `DueAt <= now` — and must carry a positive
// amount; the first that is not fails the whole call, because a partial report
// that silently dropped a receivable is worse than no report. Which
// obligation failed is not in the error: a sentinel carries no index, and
// wrapping was not worth a dependency here. A caller that needs to locate the
// bad entry has [Age] and [Obligation.Amount] and can find it in one pass.
//
// An empty slice is legitimate and returns a zeroed report, not an error: a
// realm with nothing outstanding has a provision of zero and should not have
// to special-case it.
//
// Cost: at most MaxObligations × (MaxBuckets-1) comparisons; see the package
// doc.
func (s Schedule) ReportAt(obs []Obligation, now int64) (Report, error) {
	if err := s.check(); err != nil {
		return Report{}, err
	}
	if len(obs) > MaxObligations {
		return Report{}, ErrTooManyObligations
	}
	buckets := make([]int64, len(s.edges)+1)
	var total int64
	for _, ob := range obs {
		if ob.Amount <= 0 {
			return Report{}, ErrBadAmount
		}
		age, err := Age(ob.DueAt, now)
		if err != nil {
			return Report{}, err
		}
		i, err := s.BucketOf(age)
		if err != nil {
			return Report{}, err
		}
		// Guard the running total first: it dominates every bucket, so a
		// total that fits implies every bucket fits.
		if ob.Amount > maxInt64-total {
			return Report{}, ErrOverflow
		}
		total += ob.Amount
		// And establish the PRICING precondition here, not one call later.
		// The guard above only says the total does not wrap; pricing needs
		// the stronger `b <= maxInt64/RateScale` that ProvisionByBucket
		// enforces per bucket, and the total dominates every bucket in the
		// same direction. Without this line ReportAt returned, with a nil
		// error, reports that Provision then refused with ErrOverflow — the
		// two thresholds differed by RateScale, a factor of 10,000. Measured
		// before the fix: one obligation of maxInt64 reported cleanly and
		// priced as ErrOverflow. See AUDIT.md Y1.
		//
		// Both guards are kept and both are reachable: this one fires on an
		// accumulation that cannot be priced, the one above on a single
		// amount within RateScale of maxInt64, which this one cannot see
		// because `maxInt64-total` is the quantity that wraps there.
		if total > maxInt64/RateScale {
			return Report{}, ErrOverflow
		}
		buckets[i] += ob.Amount
	}
	return Report{Buckets: buckets, Total: total}, nil
}

// ProvisionByBucket returns the expected credit loss per bucket: the
// line-item column, youngest first.
//
// Each entry is `floor(bucketᵢ × rateᵢ / RateScale)`, the floor taken per
// bucket so that this column sums to exactly what [Schedule.Provision]
// reports. See the package doc for what that choice costs, with the
// counterexample in full.
//
// The report is validated rather than trusted: its bucket count must match
// the schedule, every bucket must be non-negative, and the buckets must sum
// to the report's stated Total ([ErrCrossFoot]). A report from
// [Schedule.ReportAt] satisfies all three by construction.
//
// A fourth property is needed and is NOT one of the three: every bucket must
// be at most maxInt64/RateScale, or the multiplication below wraps. Say it
// separately because the three-item sentence above was true, complete about
// the three, and still read as "a ReportAt report always prices" — which it
// did not guarantee. ReportAt now bounds its running total by the same
// quantity, so the implicature is true; it is true because of a line in
// ReportAt, not because of anything here. See AUDIT.md Y1.
func (s Schedule) ProvisionByBucket(r Report) ([]int64, error) {
	if err := s.check(); err != nil {
		return nil, err
	}
	if len(r.Buckets) != len(s.edges)+1 {
		return nil, ErrBadReport
	}
	out := make([]int64, len(r.Buckets))
	var sum int64
	for i, b := range r.Buckets {
		if b < 0 {
			return nil, ErrBadAmount
		}
		if b > maxInt64-sum {
			return nil, ErrOverflow
		}
		sum += b
		// b*rate is the only product. The guard is per bucket rather than
		// on the total because a caller-built report's Total is not yet
		// trusted at this point — the cross-foot below is what establishes
		// it, and ordering the check the other way would let a report with
		// a wrong Total choose its own overflow precondition.
		if b > maxInt64/RateScale {
			return nil, ErrOverflow
		}
		out[i] = (b * s.rates[i]) / RateScale
	}
	if sum != r.Total {
		return nil, ErrCrossFoot
	}
	return out, nil
}

// Provision returns the expected credit loss for a report: one number for a
// ledger.
//
// It is defined as the sum of [Schedule.ProvisionByBucket], so the single
// figure and the line items can never disagree — the same reason
// [p/depreciation] defines `Charge` as a difference of `CarryingAt`. The sum
// cannot overflow: each term is at most its bucket, because every rate is at
// most RateScale, and the buckets were established to sum without overflow.
func (s Schedule) Provision(r Report) (int64, error) {
	parts, err := s.ProvisionByBucket(r)
	if err != nil {
		return 0, err
	}
	var sum int64
	for _, p := range parts {
		sum += p
	}
	return sum, nil
}

// ProvisionFor is [Schedule.ReportAt] followed by [Schedule.Provision], for a
// caller that wants the number and not the line items.
//
// Prefer it over holding a [Report]: a Report carries no reference to the
// schedule that produced it, so a stored one can be priced against a
// different schedule of the same bucket count with no error. Doing both steps
// in one call removes the opportunity.
func (s Schedule) ProvisionFor(obs []Obligation, now int64) (int64, error) {
	rep, err := s.ReportAt(obs, now)
	if err != nil {
		return 0, err
	}
	return s.Provision(rep)
}
