package oracle

import "math/overflow"

// MulDiv returns floor(a*b/den). Panics on den==0 or overflow.
// Use this for any shares/index/notional path — do not write a*b/c in int64.
func MulDiv(a, b, den int64) int64 {
	if den == 0 {
		panic("oracle: division by zero")
	}
	prod, ok := overflow.Mul64(a, b)
	if !ok {
		panic("oracle: multiplication overflow")
	}
	quot, ok := overflow.Div64(prod, den)
	if !ok {
		panic("oracle: division overflow")
	}
	return quot
}

// BpsAbs is |a-b|*10000/b. Ops bound helper, not LTV. Panics if b==0.
func BpsAbs(a, b int64) int64 {
	if b == 0 {
		panic("oracle: bps denominator")
	}
	diff := a - b
	if diff < 0 {
		diff = -diff
	}
	return MulDiv(diff, 10000, b)
}
