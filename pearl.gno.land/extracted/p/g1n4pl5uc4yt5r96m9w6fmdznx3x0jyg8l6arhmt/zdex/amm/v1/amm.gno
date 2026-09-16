package amm

import (
	"math"
	"math/bits"
	"math/overflow"
)

const bpsDen = int64(10000)

// MulDiv returns floor(a * b / d) for non-negative a, b and d > 0.
// Fast path uses int64 product. Overflow path is 128-bit (a*b)/d — same as
// int64((bigint(a)*bigint(b))/bigint(d)) — and panics only if the quotient
// does not fit int64. Gno has no typed bigint(int64) conversion.
func MulDiv(a, b, d int64) int64 {
	return mulDiv(a, b, d, false)
}

// MulDivCeil is ceil(a * b / d) for non-negative a, b and d > 0.
// Ceil only when remainder != 0.
func MulDivCeil(a, b, d int64) int64 {
	return mulDiv(a, b, d, true)
}

func mulDiv(a, b, d int64, ceil bool) int64 {
	if a < 0 || b < 0 {
		panic("zdex: negative muldiv")
	}
	if d <= 0 {
		panic("zdex: division by zero")
	}
	if a == 0 || b == 0 {
		return 0
	}
	prod, ok := overflow.Mul64(a, b)
	if ok {
		q := prod / d
		if ceil && prod%d != 0 {
			return add64(q, 1)
		}
		return q
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	du := uint64(d)
	if hi >= du {
		panic("zdex: muldiv overflow")
	}
	q, r := bits.Div64(hi, lo, du)
	if ceil && r != 0 {
		if q == uint64(math.MaxInt64) {
			panic("zdex: muldiv overflow")
		}
		q++
	}
	if q > uint64(math.MaxInt64) {
		panic("zdex: muldiv overflow")
	}
	return int64(q)
}

// Sqrt returns floor(sqrt(n)) for n >= 0 (Babylonian method).
func Sqrt(n int64) int64 {
	if n < 0 {
		panic("zdex: sqrt of negative")
	}
	if n < 2 {
		return n
	}
	x := n
	y := (x + 1) / 2
	for y < x {
		x = y
		y = (x + n/x) / 2
	}
	return x
}

func add64(a, b int64) int64 {
	s, ok := overflow.Add64(a, b)
	if !ok {
		panic("zdex: add overflow")
	}
	return s
}

// AmountOut is Uniswap-v2 getAmountOut against effective (real+virtual) reserves.
// Payout is capped by the real reserveOut — virtual offsets only affect price.
func AmountOut(amountIn, reserveIn, virtualIn, reserveOut, virtualOut, feeBps int64) int64 {
	if amountIn <= 0 {
		panic("zdex: amountIn must be positive")
	}
	if feeBps < 0 || feeBps >= bpsDen {
		panic("zdex: feeBps out of range")
	}
	x := add64(reserveIn, virtualIn)
	y := add64(reserveOut, virtualOut)
	if x <= 0 || y <= 0 {
		panic("zdex: empty effective reserves")
	}
	fee := MulDiv(amountIn, feeBps, bpsDen)
	net := amountIn - fee
	if net <= 0 {
		panic("zdex: fee consumes input")
	}
	out := MulDiv(net, y, add64(x, net))
	if out <= 0 {
		panic("zdex: zero output")
	}
	if out >= y {
		panic("zdex: would drain effective reserve")
	}
	if out >= reserveOut {
		panic("zdex: insufficient real reserve")
	}
	return out
}

// AmountIn is the ugnot/token that must be paid so AmountOut >= amountOut.
// Rounded up so ExactOut does not underpay.
func AmountIn(amountOut, reserveIn, virtualIn, reserveOut, virtualOut, feeBps int64) int64 {
	if amountOut <= 0 {
		panic("zdex: amountOut must be positive")
	}
	if feeBps < 0 || feeBps >= bpsDen {
		panic("zdex: feeBps out of range")
	}
	if amountOut >= reserveOut {
		panic("zdex: insufficient real reserve")
	}
	x := add64(reserveIn, virtualIn)
	y := add64(reserveOut, virtualOut)
	if x <= 0 || y <= 0 {
		panic("zdex: empty effective reserves")
	}
	if amountOut >= y {
		panic("zdex: would drain effective reserve")
	}
	net := MulDivCeil(amountOut, x, y-amountOut)
	in := MulDivCeil(net, bpsDen, bpsDen-feeBps)
	if in <= 0 {
		panic("zdex: zero input")
	}
	got := AmountOut(in, reserveIn, virtualIn, reserveOut, virtualOut, feeBps)
	if got < amountOut {
		in = add64(in, 1)
	}
	return in
}
