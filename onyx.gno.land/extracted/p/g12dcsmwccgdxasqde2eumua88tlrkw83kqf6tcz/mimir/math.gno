package mimir

import "math/bits"

// MulDiv returns floor(a*b/d) without overflowing the 128-bit product.
// It panics on negative inputs, a zero divisor or a result above int64.
func MulDiv(a, b, d int64) int64 {
	if a < 0 || b < 0 || d <= 0 {
		panic("mimir: MulDiv needs a, b >= 0 and d > 0")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(d) {
		panic("mimir: MulDiv overflow")
	}
	q, _ := bits.Div64(hi, lo, uint64(d))
	if q > uint64(1<<63-1) {
		panic("mimir: MulDiv overflow")
	}
	return int64(q)
}

// Add returns a+b, panicking on overflow, so a sum of stakes can never wrap.
func Add(a, b int64) int64 {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		panic("mimir: add overflow")
	}
	return c
}
