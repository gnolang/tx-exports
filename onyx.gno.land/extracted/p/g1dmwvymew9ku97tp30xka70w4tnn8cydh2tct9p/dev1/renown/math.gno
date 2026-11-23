package renown

const (
	maxInt64 int64 = 1<<63 - 1
	minInt64 int64 = -1 << 63
)

// SatAdd returns a+b, clamped to the int64 range instead of wrapping.
func SatAdd(a, b int64) int64 {
	if b > 0 && a > maxInt64-b {
		return maxInt64
	}
	if b < 0 && a < minInt64-b {
		return minInt64
	}
	return a + b
}

// SatMul returns a*b, clamped to the int64 range instead of wrapping.
func SatMul(a, b int64) int64 {
	if a == 0 || b == 0 {
		return 0
	}
	neg := (a < 0) != (b < 0)
	if a == minInt64 || b == minInt64 {
		if neg {
			return minInt64
		}
		return maxInt64
	}
	ua, ub := a, b
	if ua < 0 {
		ua = -ua
	}
	if ub < 0 {
		ub = -ub
	}
	if ua > maxInt64/ub {
		if neg {
			return minInt64
		}
		return maxInt64
	}
	return a * b
}

// MulDiv returns x*num/den for x >= 0, num >= 0, den > 0 without the
// intermediate overflow of a naive x*num. The result saturates at the int64
// maximum. Invalid inputs return 0.
func MulDiv(x, num, den int64) int64 {
	if x <= 0 || num <= 0 || den <= 0 {
		return 0
	}
	q, r := x/den, x%den
	return SatAdd(SatMul(q, num), SatMul(r, num)/den)
}

// Min returns the smaller of a and b.
func Min(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
