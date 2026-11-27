package townmath

// Shared customer pool math. All customers of an hour form one pool that is
// split among pubs by weight. Everything is integer math, no floats.

// Defaults for the pool exponent step count and the demand scale. They may be
// tuned later.
const (
	PoolExponentK       = 2
	PoolScaleBps  int64 = 10000
)

// Input caps that keep every intermediate product far below int64 overflow.
const (
	maxPoolPubs   int64 = 1000000
	maxPoolMilli  int64 = 10000000
	maxPoolWeight int64 = 100000000
	maxPoolScale  int64 = 100000
	maxSeatsInPub int64 = 50
)

// maxSqrtArg is the floor of the square root of the largest int64.
const maxSqrtArg int64 = 3037000499

// isqrt returns floor(sqrt(x)) by binary search. x <= 0 gives 0. The loop
// runs at most 32 times.
func isqrt(x int64) int64 {
	if x <= 0 {
		return 0
	}
	lo, hi := int64(0), maxSqrtArg
	if x < hi {
		hi = x
	}
	for i := 0; i < 40 && lo < hi; i++ {
		mid := lo + (hi-lo+1)/2
		if mid*mid <= x {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

// PoolPowMilli returns n^(1 - 2^-k) * 1000. k is clamped to 1..3 (n^0.5,
// n^0.75, n^0.875). n <= 0 gives 0 and n is capped at 1,000,000. The pool
// grows with the number of pubs, but slower than the pub count, so adding
// pubs never multiplies the customers per pub.
func PoolPowMilli(n int64, k int) int64 {
	if n <= 0 {
		return 0
	}
	if n > maxPoolPubs {
		n = maxPoolPubs
	}
	if k < 1 {
		k = 1
	}
	if k > 3 {
		k = 3
	}
	scaled := n * 1000000
	// r ends as n^(2^-k) * 1000.
	r := isqrt(scaled)
	for i := 1; i < k; i++ {
		r = isqrt(r * 1000)
	}
	if r == 0 {
		return 0
	}
	return scaled / r
}

// PoolCustomersMilli returns the customers (in thousandths) that walk in
// during one hour for a town of pubs pubs: the hour curve times the pool
// power, scaled by scaleBps (clamped to 0..100000).
func PoolCustomersMilli(hour int, pubs int64, k int, scaleBps int64) int64 {
	return MulBps(HourCurve(hour)*PoolPowMilli(pubs, k), clamp(scaleBps, 0, maxPoolScale))
}

// WeightIn holds the inputs that decide a pub's share of the pool.
type WeightIn struct {
	PriceCg, MarketCg, Rep, Seats, StaffBps, AdBps int64
}

// PubWeight returns a pub's pull on the pool: price, reputation, staff and
// ad factors (basis points) times its seats (0..50).
func PubWeight(in WeightIn) int64 {
	f := MulBps(PriceFactorBps(in.PriceCg, in.MarketCg), RepFactorBps(in.Rep))
	f = MulBps(f, clamp(in.StaffBps, 5000, 20000))
	f = MulBps(f, clamp(in.AdBps, 10000, 20000))
	return f * clamp(in.Seats, 0, maxSeatsInPub)
}

// PubShareMilli returns a pub's part of the pool: poolMilli * weight /
// totalWeight, rounded down. Any argument <= 0 gives 0. A weight at or above
// the total takes the whole (capped) pool.
func PubShareMilli(poolMilli, weight, totalWeight int64) int64 {
	if poolMilli <= 0 || weight <= 0 || totalWeight <= 0 {
		return 0
	}
	poolMilli = min64(poolMilli, maxPoolMilli)
	if weight >= totalWeight {
		return poolMilli
	}
	weight = min64(weight, maxPoolWeight)
	return poolMilli * weight / totalWeight
}

// CarryDemand adds a fractional carry (0..999) to milli customers and returns
// the whole customers plus the new carry. Negative milli counts as 0.
func CarryDemand(milli, carry int64) (customers, newCarry int64) {
	if milli < 0 {
		milli = 0
	}
	total := milli + clamp(carry, 0, 999)
	return total / 1000, total % 1000
}
