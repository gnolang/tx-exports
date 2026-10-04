package physics

import "math"

// fsqrt is math.Sqrt, bit for bit, at a fraction of its gas.
//
// gno's math.Sqrt computes the root one bit at a time in interpreted code
// (~170k gas); the engine takes several roots every millisecond step. Here a
// float Newton iteration gets within a unit in the last place, and an exact
// integer test settles the last bit: for x = M * 2^e (e even) the correctly
// rounded root is R * 2^q, q = e/2 - 26, where R is the integer nearest
// sqrt(N), N = M * 2^52, and R is that integer exactly when
// R*R - R < N <= R*R + R (no square root of an integer lies halfway between
// two integers). N - R*R is small, so it is computed exactly mod 2^64. A
// Newton result one ulp off is moved by that ulp; anything else (rare) goes
// to sqrtSlow. Zero, subnormals, infinities and NaN go to math.Sqrt.
func fsqrt(x float64) float64 {
	b := math.Float64bits(x)
	if b-1<<52 >= 0x7fe0000000000000 { // negative, zero, subnormal, infinite or NaN
		return math.Sqrt(x)
	}
	y := math.Float64frombits((b >> 1) + 0x1ff8000000000000)
	y = 0.5 * (y + x/y)
	y = 0.5 * (y + x/y)
	y = 0.5 * (y + x/y)
	y = 0.5 * (y + x/y)
	yb := math.Float64bits(y)
	// x = m * 2^(ex), y = R * 2^q: y is the root when R*R - R < N <= R*R + R
	// for N = m * 2^(ex-2q), which is m << 52 or m << 53 when y is in the
	// root's binade.
	s := b>>52 - yb>>52<<1 + 1075
	if s-52 > 1 {
		return sqrtSlow(x)
	}
	R := yb&(1<<52-1) | 1<<52
	N := (b&(1<<52-1) | 1<<52) << s
	d := int64(N - R*R)
	if d > int64(R) {
		// One ulp low: R+1 is the root when N - (R+1)^2 = d - 2R - 1 is in range.
		if d2 := d - int64(R<<1) - 1; d2 <= int64(R+1) && d2 > -int64(R+1) && R+1 < 1<<53 {
			return math.Float64frombits(yb + 1)
		}
		return sqrtSlow(x)
	}
	if d <= -int64(R) {
		if d2 := d + int64(R<<1) - 1; d2 <= int64(R-1) && d2 > -int64(R-1) && R > 1<<52 {
			return math.Float64frombits(yb - 1)
		}
		return sqrtSlow(x)
	}
	return y
}

// sqrtSlow settles the roots the fast path cannot: the general case.
func sqrtSlow(x float64) float64 {
	b := math.Float64bits(x)
	exp := int(b>>52) & 0x7ff
	if b>>63 != 0 || exp == 0 || exp == 0x7ff {
		return math.Sqrt(x)
	}
	// Halve the exponent, then four Newton steps: within an ulp.
	y := math.Float64frombits((b >> 1) + 0x1ff8000000000000)
	y = 0.5 * (y + x/y)
	y = 0.5 * (y + x/y)
	y = 0.5 * (y + x/y)
	y = 0.5 * (y + x/y)

	m := b&(1<<52-1) | 1<<52
	e := exp - 1075 // x = m * 2^e
	if e&1 != 0 {
		m <<= 1
		e--
	}
	N := m << 52
	yb := math.Float64bits(y)
	if int(yb>>52) != e/2+1049 { // y is not in the root's binade: settle it the long way
		return rootOf(N, e/2-26, y)
	}
	R := yb&(1<<52-1) | 1<<52 // y = R * 2^q
	d := int64(N - R*R)
	if d > int64(R) {
		if d2 := int64(N - (R+1)*(R+1)); d2 > int64(R+1) || d2 <= -int64(R+1) {
			return rootOf(N, e/2-26, y)
		}
		return math.Float64frombits(yb + 1)
	}
	if d <= -int64(R) {
		if R == 1<<52 {
			return rootOf(N, e/2-26, y)
		}
		if d2 := int64(N - (R-1)*(R-1)); d2 > int64(R-1) || d2 <= -int64(R-1) {
			return rootOf(N, e/2-26, y)
		}
		return math.Float64frombits(yb - 1)
	}
	return y
}

// rootOf is the general case: R from the estimate y, an integer Newton step,
// then whole units until R is the nearest integer to sqrt(N).
func rootOf(N uint64, q int, y float64) float64 {
	R := uint64(y * math.Float64frombits(uint64(1023-q)<<52))
	d := int64(N - R*R)
	R = uint64(int64(R) + d/int64(2*R))
	for {
		d = int64(N - R*R)
		if d > int64(R) {
			R++
		} else if d <= -int64(R) {
			R--
		} else {
			break
		}
	}
	return float64(R) * math.Float64frombits(uint64(q+1023)<<52)
}
