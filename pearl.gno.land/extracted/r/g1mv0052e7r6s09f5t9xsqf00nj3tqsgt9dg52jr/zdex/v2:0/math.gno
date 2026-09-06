package zdex

import (
	"math/overflow"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/zdex/amm/v1"
)

// AMM formula lives in gno.land/p/<g1>/zdex/amm/v1 on Pearl (namespace
// "zdex" is not authorized). Local source still imports gno.land/p/zdex/amm/v1.
// ship without touching LP, book, or points in this realm. These wrappers
// keep the v1 MsgCall/qeval names stable.

func MulDiv(a, b, d int64) int64 {
	return amm.MulDiv(a, b, d)
}

func Sqrt(n int64) int64 {
	return amm.Sqrt(n)
}

func MulDivCeil(a, b, d int64) int64 {
	return amm.MulDivCeil(a, b, d)
}

func AmountOut(amountIn, reserveIn, virtualIn, reserveOut, virtualOut, feeBps int64) int64 {
	return amm.AmountOut(amountIn, reserveIn, virtualIn, reserveOut, virtualOut, feeBps)
}

func AmountIn(amountOut, reserveIn, virtualIn, reserveOut, virtualOut, feeBps int64) int64 {
	return amm.AmountIn(amountOut, reserveIn, virtualIn, reserveOut, virtualOut, feeBps)
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
