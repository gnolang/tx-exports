package zdex

import "math/overflow"

// MulDiv returns floor(a * b / d) for non-negative a, b and d > 0.
// When a*b overflows int64, rearranges to a1*b + a0*b/d with a = a1*d + a0
// so constant-product math still works for typical GRC20 reserves.
func MulDiv(a, b, d int64) int64 {
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
		return prod / d
	}
	// a*b overflowed. a = a1*d + a0  →  a*b/d = a1*b + a0*b/d
	a1 := a / d
	a0 := a % d
	p1, ok1 := overflow.Mul64(a1, b)
	if !ok1 {
		panic("zdex: muldiv overflow")
	}
	// a0*b may still overflow; a0 < d so a0*(b/d) < b and fits.
	b1 := b / d
	b0 := b % d
	p2, ok2 := overflow.Mul64(a0, b1)
	if !ok2 {
		panic("zdex: muldiv overflow")
	}
	p3, ok3 := overflow.Mul64(a0, b0)
	if !ok3 {
		// a0*b0 < d*d; if d is huge this can overflow even when the
		// quotient fits. Scale down by gcd-like split: (a0/2)*(b0)*2/d.
		panic("zdex: muldiv overflow")
	}
	sum, ok4 := overflow.Add64(p1, p2)
	if !ok4 {
		panic("zdex: muldiv overflow")
	}
	sum, ok4 = overflow.Add64(sum, p3/d)
	if !ok4 {
		panic("zdex: muldiv overflow")
	}
	return sum
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

func geoMean(a, b int64) int64 {
	prod, ok := overflow.Mul64(a, b)
	if ok {
		return Sqrt(prod)
	}
	return MulDiv(Sqrt(a), Sqrt(b), 1)
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}

func add64(a, b int64) int64 {
	s, ok := overflow.Add64(a, b)
	if !ok {
		panic("zdex: add overflow")
	}
	return s
}

func sub64(a, b int64) int64 {
	if b > a {
		panic("zdex: sub underflow")
	}
	return a - b
}

// AmountOut is Uniswap-v2 getAmountOut against effective (real+virtual) reserves.
// Payout is capped by the real reserveOut — virtual offsets only affect price.
func AmountOut(amountIn, reserveIn, virtualIn, reserveOut, virtualOut, feeBps int64) int64 {
	if amountIn <= 0 {
		panic("zdex: amountIn must be positive")
	}
	if feeBps < 0 || feeBps >= 10000 {
		panic("zdex: feeBps out of range")
	}
	x := add64(reserveIn, virtualIn)
	y := add64(reserveOut, virtualOut)
	if x <= 0 || y <= 0 {
		panic("zdex: empty effective reserves")
	}
	fee := MulDiv(amountIn, feeBps, 10000)
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

type feeSplit struct {
	gross    int64
	net      int64
	lp       int64
	creator  int64
	protocol int64
}

func splitFee(amountIn, feeBps, creatorBps, protocolBps int64) feeSplit {
	if feeBps < 0 || feeBps >= 10000 {
		panic("zdex: feeBps out of range")
	}
	if creatorBps < 0 || protocolBps < 0 || creatorBps+protocolBps > 10000 {
		panic("zdex: fee share out of range")
	}
	fee := MulDiv(amountIn, feeBps, 10000)
	net := amountIn - fee
	creator := MulDiv(fee, creatorBps, 10000)
	protocol := MulDiv(fee, protocolBps, 10000)
	lp := fee - creator - protocol
	if lp < 0 {
		panic("zdex: fee split underflow")
	}
	return feeSplit{gross: amountIn, net: net, lp: lp, creator: creator, protocol: protocol}
}
