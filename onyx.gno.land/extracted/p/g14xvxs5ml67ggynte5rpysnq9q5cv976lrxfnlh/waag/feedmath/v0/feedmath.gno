// Package feedmath is the oracle's pure-math core: fixed-point prices,
// median-of-N aggregation, the deviation guard, and the staleness predicate.
//
// It is a /p/ package, not a realm: no persistent state, no caller context, no
// chain access. That split is deliberate. Every rule the feed depends on lives
// here so it can be tested exhaustively and cheaply, and so the realm layer
// holds only plumbing (authorization, storage, events).
//
// Facts verified 2026-11-25 against gnolang/gno tag v1.8.0 (primary sources):
//
//   - gnovm/stdlibs/chain/runtime/native.gno declares `ChainHeight() int64`,
//     so block heights are int64 everywhere in this project (the master doc's
//     earlier "uint64" note was wrong and has been corrected).
//   - No float type appears in this file: on-chain floats are forbidden
//     (ledger O7) because their rounding is not reproducible across nodes.
//   - Sorting is hand-rolled insertion sort rather than stdlib `sort`: n is the
//     number of registered sources (3 today, single digits ever), where
//     insertion sort is cheaper and avoids reflection-driven gas.
//   - examples/gno.land/p/nt/avl/v0/tree_test.gno confirms pure-package tests
//     take `(t *testing.T)` with no realm parameter; revive() for panic
//     assertions follows examples/gno.land/p/nt/grc20/v0/token_test.gno.
package feedmath

// Price is a USD price in fixed point, scaled by Scale:
//
//	$0.04905   ->        49050
//	$1.00      ->      1000000
//	$100000.00 -> 100000000000
//
// Integers only. One unit is one millionth of a dollar, which is far finer
// than any exchange quotes GNOT at, so no real precision is lost.
type Price int64

const (
	// Scale is the fixed-point multiplier: Price = USD * Scale.
	Scale = int64(1000000)

	// BpsScale is the denominator for basis-point thresholds. One basis point
	// is 0.01%, so a 10% guard is 1000 bps.
	BpsScale = int64(10000)

	// MaxThresholdBps caps tunable deviation thresholds at 100%. A guard wider
	// than 100% would accept a price of $0 against a reference of $1, which is
	// not a guard at all.
	MaxThresholdBps = int64(10000)

	// MaxPrice bounds every accepted price. Two reasons:
	//
	//  1. It keeps the deviation guard's intermediate products inside int64.
	//     The widest possible gap is MaxPrice-1, and (MaxPrice-1)*BpsScale is
	//     about 1e18 versus an int64 limit near 9.22e18 - roughly 9x headroom.
	//  2. It rejects nonsense quotes early instead of letting them corrupt a
	//     published median.
	//
	// 1e14 units == $100,000,000 at Scale: comfortably above any real asset
	// price, so the bound costs nothing in practice.
	MaxPrice = Price(100000000000000)
)

// ---- Validation ----------------------------------------------------------

// ValidPrice reports whether p may enter the system: strictly positive and
// within the overflow-safe bound.
//
// Zero is invalid on purpose. A "price" of $0 is not a quote, it is a missing
// or broken quote, and letting it into a median would drag the published feed
// toward zero - exactly the failure mode an oracle must never have.
func ValidPrice(p Price) bool {
	return p > 0 && p <= MaxPrice
}

// MustValidPrice panics unless ValidPrice(p) holds.
//
// Call it on every price crossing into the system. On-chain, a panic reverts
// the whole transaction and rolls back its state changes, which is precisely
// what a malformed submission deserves: it is a rejected transaction, not a
// stored bad number.
func MustValidPrice(p Price) {
	if !ValidPrice(p) {
		panic("feedmath: price must be > 0 and <= MaxPrice")
	}
}

// AbsDiff returns |a - b| for two valid prices.
//
// Validity is what makes this safe: with both operands in (0, MaxPrice], the
// subtraction can never overflow, so no wider intermediate type is needed.
func AbsDiff(a, b Price) Price {
	MustValidPrice(a)
	MustValidPrice(b)
	if a >= b {
		return a - b
	}
	return b - a
}

// ---- Aggregation (ledger O3: median of fresh submissions) ----------------

// Median3 returns the median of exactly three prices: the middle value once
// they are ordered.
//
// Median, not mean. A mean can be pulled arbitrarily far by one outlier - a
// single bogus $9999 quote among two honest ones wrecks the average. A median
// of three cannot be moved at all by one bad value: the two honest ones still
// outvote it. That resistance is the whole reason the aggregation rule is a
// median.
//
// Panics if any input is not a valid price.
func Median3(a, b, c Price) Price {
	MustValidPrice(a)
	MustValidPrice(b)
	MustValidPrice(c)

	// Middle-of-three by comparison. Cheaper and more predictable in gas than
	// building a slice and sorting it, and trivially checkable by hand.
	if a > b {
		a, b = b, a // now a <= b
	}
	if b > c {
		b = c // now b = min(b, c)
	}
	if a > b {
		b = a // now b = max(a, b), i.e. the middle of the three
	}
	return b
}

// MedianN returns the median of any non-empty slice of prices.
//
// Even-length inputs have no single middle element. By convention this returns
// the floor of the average of the two middle prices - integer division, so the
// result is at most one unit ($0.000001) below the true midpoint. The oracle
// only ever feeds an odd number of sources today, but the even case is defined
// rather than left to chance.
//
// The midpoint is computed as lo + (hi-lo)/2 rather than the more obvious
// (lo+hi)/2. Given ValidPrice's cap, both are safe today - but the first stays
// correct even if MaxPrice were ever raised toward the int64 limit, so the
// average can never become the thing that overflows. Same result, no trap
// waiting on a future constant change.
//
// The input slice is copied and never reordered - a caller's slice is not ours
// to mutate. Panics on an empty slice or any invalid price.
func MedianN(ps []Price) Price {
	if len(ps) == 0 {
		panic("feedmath: MedianN needs at least one price")
	}

	sorted := make([]Price, len(ps))
	copy(sorted, ps)
	for i := 0; i < len(sorted); i++ {
		MustValidPrice(sorted[i])
	}
	insertionSort(sorted)

	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid]
	}
	lo, hi := sorted[mid-1], sorted[mid]
	return lo + (hi-lo)/2
}

// insertionSort orders prices ascending, in place.
//
// Insertion sort because n is the count of registered sources: at that size it
// beats every general-purpose sort on both speed and gas, has no reflection,
// and is short enough to verify by reading it once.
func insertionSort(ps []Price) {
	for i := 1; i < len(ps); i++ {
		v := ps[i]
		j := i - 1
		for j >= 0 && ps[j] > v {
			ps[j+1] = ps[j]
			j--
		}
		ps[j+1] = v
	}
}
