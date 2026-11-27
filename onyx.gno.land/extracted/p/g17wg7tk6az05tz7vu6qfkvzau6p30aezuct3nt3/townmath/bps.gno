// Package townmath holds the pure integer formulas shared by the town realm,
// the villagers realm and (later) a Go operator server. No state, no floats.
package townmath

// BpsOne is 100% in basis points.
const BpsOne int64 = 10000

// MulBps returns x * bps / 10000 without overflowing for large x.
// It splits x so the intermediate products stay small:
// x/10000*bps + x%10000*bps/10000.
func MulBps(x, bps int64) int64 {
	return x/BpsOne*bps + x%BpsOne*bps/BpsOne
}

// clamp limits v to the range [lo, hi].
func clamp(v, lo, hi int64) int64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
