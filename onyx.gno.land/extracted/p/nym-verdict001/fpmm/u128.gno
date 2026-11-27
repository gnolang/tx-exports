package fpmm

import "math/bits"

// u128 represents an unsigned 128-bit integer for overflow-free
// fixed-point intermediate arithmetic.
type u128 struct {
	hi uint64
	lo uint64
}

func u128From64(x uint64) u128 {
	return u128{lo: x}
}

func u128Add(a, b u128) (u128, bool) {
	lo, carry := bits.Add64(a.lo, b.lo, 0)
	hi, carryOut := bits.Add64(a.hi, b.hi, carry)
	if carryOut != 0 {
		return u128{}, false
	}
	return u128{hi: hi, lo: lo}, true
}

func u128Sub(a, b u128) (u128, bool) {
	lo, borrow := bits.Sub64(a.lo, b.lo, 0)
	hi, borrowOut := bits.Sub64(a.hi, b.hi, borrow)
	if borrowOut != 0 {
		return u128{}, false
	}
	return u128{hi: hi, lo: lo}, true
}

func u128Cmp(a, b u128) int {
	if a.hi < b.hi {
		return -1
	}
	if a.hi > b.hi {
		return 1
	}
	if a.lo < b.lo {
		return -1
	}
	if a.lo > b.lo {
		return 1
	}
	return 0
}

func u128Mul64(a, b uint64) u128 {
	hi, lo := bits.Mul64(a, b)
	return u128{hi: hi, lo: lo}
}

func u128Div64(a u128, d uint64) (u128, uint64) {
	if d == 0 {
		panic("fpmm: division by zero")
	}
	qHi := a.hi / d
	rHi := a.hi % d
	qLo, rem := bits.Div64(rHi, a.lo, d)
	return u128{hi: qHi, lo: qLo}, rem
}

func mulDivFloor(a, b, d uint64) (uint64, bool) {
	if d == 0 {
		return 0, false
	}
	prod := u128Mul64(a, b)
	q, _ := u128Div64(prod, d)
	if q.hi != 0 {
		return 0, false
	}
	return q.lo, true
}

func mulDivCeil(a, b, d uint64) (uint64, bool) {
	if d == 0 {
		return 0, false
	}
	prod := u128Mul64(a, b)
	q, rem := u128Div64(prod, d)
	if q.hi != 0 {
		return 0, false
	}
	if rem > 0 {
		if q.lo == ^uint64(0) {
			return 0, false
		}
		q.lo++
	}
	return q.lo, true
}

func u128BitLen(n u128) int {
	if n.hi > 0 {
		return 64 + bits.Len64(n.hi)
	}
	return bits.Len64(n.lo)
}

func u128SqrtFloor(n u128) uint64 {
	if n.hi == 0 && n.lo <= 1 {
		return n.lo
	}
	bitLen := u128BitLen(n)
	shiftLo := uint((bitLen - 1) / 2)
	shiftHi := uint((bitLen + 1) / 2)

	lo := uint64(1) << shiftLo
	var hi uint64
	if shiftHi >= 64 {
		hi = ^uint64(0)
	} else {
		hi = (uint64(1) << shiftHi) - 1
	}

	for lo < hi {
		mid := lo + (hi-lo+1)/2
		sq := u128Mul64(mid, mid)
		if u128Cmp(sq, n) <= 0 {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

func u128SqrtCeil(n u128) (uint64, bool) {
	r := u128SqrtFloor(n)
	sq := u128Mul64(r, r)
	if u128Cmp(sq, n) < 0 {
		if r == ^uint64(0) {
			return 0, false
		}
		r++
	}
	return r, true
}

// mulAccDiv computes floor(acc * shares / scale) or ceil(acc * shares / scale)
// using exact 192-bit intermediate multiplication and 3-limb division.
func mulAccDiv(acc u128, shares, scale uint64, ceil bool) (int64, bool) {
	if scale == 0 {
		return 0, false
	}
	p0Hi, w0 := bits.Mul64(acc.lo, shares)
	p1Hi, p1Lo := bits.Mul64(acc.hi, shares)

	w1, c1 := bits.Add64(p1Lo, p0Hi, 0)
	w2, c2 := bits.Add64(p1Hi, 0, c1)
	if c2 != 0 {
		return 0, false
	}

	q2 := w2 / scale
	r2 := w2 % scale
	if q2 != 0 {
		return 0, false
	}
	q1, r1 := bits.Div64(r2, w1, scale)
	if q1 != 0 {
		return 0, false
	}
	q0, rem := bits.Div64(r1, w0, scale)
	if ceil && rem > 0 {
		if q0 == ^uint64(0) {
			return 0, false
		}
		q0++
	}
	if q0 > uint64(maxInt64) {
		return 0, false
	}
	return int64(q0), true
}
