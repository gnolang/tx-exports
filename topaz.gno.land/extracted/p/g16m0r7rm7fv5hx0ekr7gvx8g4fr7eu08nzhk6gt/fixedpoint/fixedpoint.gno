// Package fixedpoint provides deterministic decimal arithmetic with a
// fixed number of decimal places, backed by int64. gno.land has no
// float type reachable from consensus-critical code (and even if it
// did, floats aren't deterministic across platforms), so any realm
// doing price/ratio/percentage math needs something like this instead
// of drifting into ad-hoc basis-points arithmetic scattered everywhere.
//
// A Fixed value stores its number scaled by 10^Decimals in Raw. All
// arithmetic is overflow-checked via math/overflow and panics rather
// than silently wrapping -- a wrapped overflow in financial math is a
// far worse failure mode than a loud panic.
package fixedpoint

import (
	"math/overflow"

	"gno.land/p/nt/ufmt/v0"
)

const Decimals = 6

const Scale int64 = 1000000

type Fixed struct {
	Raw int64
}

func FromInt(i int64) Fixed {
	raw, ok := overflow.Mul64(i, Scale)
	if !ok {
		panic("fixedpoint: FromInt overflowed")
	}
	return Fixed{Raw: raw}
}

func FromRaw(raw int64) Fixed {
	return Fixed{Raw: raw}
}

func (f Fixed) Add(other Fixed) Fixed {
	raw, ok := overflow.Add64(f.Raw, other.Raw)
	if !ok {
		panic("fixedpoint: Add overflowed")
	}
	return Fixed{Raw: raw}
}

func (f Fixed) Sub(other Fixed) Fixed {
	raw, ok := overflow.Sub64(f.Raw, other.Raw)
	if !ok {
		panic("fixedpoint: Sub overflowed")
	}
	return Fixed{Raw: raw}
}

func (f Fixed) Mul(other Fixed) Fixed {
	product, ok := overflow.Mul64(f.Raw, other.Raw)
	if !ok {
		panic("fixedpoint: Mul overflowed")
	}
	return Fixed{Raw: product / Scale}
}

func (f Fixed) Div(other Fixed) Fixed {
	if other.Raw == 0 {
		panic("fixedpoint: division by zero")
	}
	scaled, ok := overflow.Mul64(f.Raw, Scale)
	if !ok {
		panic("fixedpoint: Div overflowed")
	}
	return Fixed{Raw: scaled / other.Raw}
}

func (f Fixed) IsZero() bool {
	return f.Raw == 0
}

func (f Fixed) IsNegative() bool {
	return f.Raw < 0
}

func (f Fixed) Cmp(other Fixed) int {
	if f.Raw < other.Raw {
		return -1
	}
	if f.Raw > other.Raw {
		return 1
	}
	return 0
}

func (f Fixed) String() string {
	raw := f.Raw
	negative := raw < 0
	if negative {
		raw = -raw
	}

	whole := raw / Scale
	frac := raw % Scale

	fracStr := ufmt.Sprintf("%d", frac)
	for len(fracStr) < Decimals {
		fracStr = "0" + fracStr
	}

	sign := ""
	if negative {
		sign = "-"
	}

	return ufmt.Sprintf("%s%d.%s", sign, whole, fracStr)
}
