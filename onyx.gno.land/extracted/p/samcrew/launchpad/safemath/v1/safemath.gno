// Package safemath is checked, non-negative int64 arithmetic for launchpad amounts.
package safemath

import "math/bits"

const (
	MaxInt64       int64 = 1<<63 - 1
	BPSDenominator int64 = 10_000
)

func mustNonNegative(v int64) {
	if v < 0 {
		panic("launchpad/safemath: negative value")
	}
}

func Add(a, b int64) int64 {
	mustNonNegative(a)
	mustNonNegative(b)
	if a > MaxInt64-b {
		panic("launchpad/safemath: overflow")
	}
	return a + b
}

func Sub(a, b int64) int64 {
	mustNonNegative(a)
	mustNonNegative(b)
	if b > a {
		panic("launchpad/safemath: underflow")
	}
	return a - b
}

func Mul(a, b int64) int64 {
	mustNonNegative(a)
	mustNonNegative(b)
	if a != 0 && b > MaxInt64/a {
		panic("launchpad/safemath: overflow")
	}
	return a * b
}

// MulDiv returns floor(a*b/d) using a 128-bit intermediate.
func MulDiv(a, b, d int64) int64 {
	q, _ := mulDivRem(a, b, d)
	return q
}

// MulDivUp returns ceil(a*b/d) using a 128-bit intermediate.
func MulDivUp(a, b, d int64) int64 {
	q, rem := mulDivRem(a, b, d)
	if rem {
		if q == MaxInt64 {
			panic("launchpad/safemath: overflow")
		}
		q++
	}
	return q
}

func mulDivRem(a, b, d int64) (int64, bool) {
	mustNonNegative(a)
	mustNonNegative(b)
	if d <= 0 {
		panic("launchpad/safemath: division by zero")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(d) {
		panic("launchpad/safemath: overflow")
	}
	q, r := bits.Div64(hi, lo, uint64(d))
	if q > uint64(MaxInt64) {
		panic("launchpad/safemath: overflow")
	}
	return int64(q), r != 0
}

// BPS returns floor(amount*bps/10000) for 0 <= bps <= 10000.
func BPS(amount, bps int64) int64 {
	if bps < 0 || bps > BPSDenominator {
		panic("launchpad/safemath: basis points out of range")
	}
	return MulDiv(amount, bps, BPSDenominator)
}

func Min(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
