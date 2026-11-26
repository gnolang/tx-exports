package qfmath

// u128 provides minimal, deterministic, zero-float 128-bit unsigned integer
// arithmetic so quadratic funding sums, pairwise overlap denominators, HHI
// concentration scores, and Hamilton apportionment remain overflow-free across
// the entire positive int64 domain.
type u128 struct {
	hi uint64
	lo uint64
}

func u128From64(v uint64) u128 {
	return u128{hi: 0, lo: v}
}

func (a u128) isZero() bool {
	return a.hi == 0 && a.lo == 0
}

func (a u128) cmp(b u128) int {
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

func add128(a, b u128) u128 {
	lo := a.lo + b.lo
	carry := uint64(0)
	if lo < a.lo {
		carry = 1
	}
	hi := a.hi + b.hi + carry
	if hi < a.hi || (carry == 1 && hi == a.hi) {
		panic("qfmath: u128 addition overflow")
	}
	return u128{hi: hi, lo: lo}
}

func sub128(a, b u128) u128 {
	borrow := uint64(0)
	if a.lo < b.lo {
		borrow = 1
	}
	lo := a.lo - b.lo
	if a.hi < b.hi+borrow {
		panic("qfmath: u128 subtraction underflow")
	}
	hi := a.hi - b.hi - borrow
	return u128{hi: hi, lo: lo}
}

// mul64 multiplies two uint64 values into an exact 128-bit product.
func mul64(x, y uint64) u128 {
	const mask32 = (uint64(1) << 32) - 1
	x0 := x & mask32
	x1 := x >> 32
	y0 := y & mask32
	y1 := y >> 32

	w0 := x0 * y0
	t := x1*y0 + (w0 >> 32)
	w1 := t & mask32
	w2 := t >> 32
	w1 += x0 * y1

	hi := x1*y1 + w2 + (w1 >> 32)
	lo := (w1 << 32) | (w0 & mask32)
	return u128{hi: hi, lo: lo}
}

// mul128By64 multiplies a u128 by a uint64, panicking on 128-bit overflow.
func mul128By64(a u128, b uint64) u128 {
	loProd := mul64(a.lo, b)
	hiProd := mul64(a.hi, b)
	if hiProd.hi != 0 {
		panic("qfmath: u128 multiplication overflow")
	}
	hi := hiProd.lo + loProd.hi
	if hi < hiProd.lo {
		panic("qfmath: u128 multiplication overflow")
	}
	return u128{hi: hi, lo: loProd.lo}
}

func bitLen64(v uint64) int {
	n := 0
	for v > 0 {
		v >>= 1
		n++
	}
	return n
}

func (a u128) bitLen() int {
	if a.hi != 0 {
		return 64 + bitLen64(a.hi)
	}
	return bitLen64(a.lo)
}

func (a u128) lsh(n uint) u128 {
	if n == 0 {
		return a
	}
	if n >= 128 {
		return u128{}
	}
	if n >= 64 {
		return u128{hi: a.lo << (n - 64), lo: 0}
	}
	return u128{
		hi: (a.hi << n) | (a.lo >> (64 - n)),
		lo: a.lo << n,
	}
}

func (a u128) rsh(n uint) u128 {
	if n == 0 {
		return a
	}
	if n >= 128 {
		return u128{}
	}
	if n >= 64 {
		return u128{hi: 0, lo: a.hi >> (n - 64)}
	}
	return u128{
		hi: a.hi >> n,
		lo: (a.lo >> n) | (a.hi << (64 - n)),
	}
}

func (a u128) bit(pos uint) uint64 {
	if pos >= 128 {
		return 0
	}
	if pos >= 64 {
		return (a.hi >> (pos - 64)) & 1
	}
	return (a.lo >> pos) & 1
}

func (a u128) setBit(pos uint) u128 {
	if pos >= 64 {
		a.hi |= uint64(1) << (pos - 64)
	} else {
		a.lo |= uint64(1) << pos
	}
	return a
}

// divRem128 computes quotient q and remainder r such that a = q*b + r and 0 <= r < b.
func divRem128(a, b u128) (q, r u128) {
	if b.isZero() {
		panic("qfmath: division by zero")
	}
	if a.cmp(b) < 0 {
		return u128{}, a
	}
	if a.hi == 0 && b.hi == 0 {
		return u128From64(a.lo / b.lo), u128From64(a.lo % b.lo)
	}

	bits := a.bitLen()
	for i := bits - 1; i >= 0; i-- {
		r = r.lsh(1)
		r.lo |= a.bit(uint(i))
		if r.cmp(b) >= 0 {
			r = sub128(r, b)
			q = q.setBit(uint(i))
		}
	}
	return q, r
}

// isqrt128 returns floor(sqrt(n)) as a uint64 for any u128 value.
// For any n < 2^128, floor(sqrt(n)) < 2^64 and always fits in uint64.
func isqrt128(n u128) uint64 {
	if n.isZero() {
		return 0
	}
	if n.hi == 0 {
		return isqrt64u(n.lo)
	}
	// Binary search on the exact bit length half-range [0, 2^64-1].
	shift := uint((n.bitLen() + 1) / 2)
	var lo, hi uint64
	if shift >= 64 {
		hi = ^uint64(0)
	} else {
		hi = (uint64(1) << shift) - 1
	}
	if shift > 1 {
		lo = uint64(1) << (shift - 1)
	}
	for lo < hi {
		// mid = lo + (hi - lo + 1) / 2 avoiding uint64 overflow
		mid := lo + ((hi - lo) >> 1) + ((hi - lo) & 1)
		sq := mul64(mid, mid)
		cmp := sq.cmp(n)
		if cmp == 0 {
			return mid
		}
		if cmp < 0 {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	return lo
}

// isqrt64u computes exact floor(sqrt(u)) for any uint64 using Newton's method.
func isqrt64u(u uint64) uint64 {
	if u < 2 {
		return u
	}
	// Initial overestimate x0 >= sqrt(u) guarantees monotonic convergence.
	shift := uint((bitLen64(u) + 1) / 2)
	var x uint64
	if shift >= 32 {
		x = (uint64(1) << 32) - 1
	} else {
		x = uint64(1) << shift
	}
	for {
		next := (x + u/x) >> 1
		if next >= x {
			// Guard against underestimate when shift was capped at 32.
			for x < ^uint64(0) && mul64(x+1, x+1).cmp(u128From64(u)) <= 0 {
				x++
			}
			return x
		}
		x = next
	}
}
