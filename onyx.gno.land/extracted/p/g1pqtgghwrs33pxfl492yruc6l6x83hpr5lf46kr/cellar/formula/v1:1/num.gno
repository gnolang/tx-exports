package formula

import (
	"math/bits"
	"strconv"
	"strings"
)

// Num is a fixed-point decimal: a count of millionths.
// Valid values lie in [-MaxNum, MaxNum].
type Num int64

const (
	// Unit is the Num that represents 1.
	Unit Num = 1000000
	// MaxNum is the largest Num, 9223372036854.775807.
	MaxNum Num = 1<<63 - 1

	decimals = 6
)

// Int returns the Num for a whole number, and whether it fits.
func Int(i int64) (Num, bool) {
	const limit = int64(MaxNum) / int64(Unit)
	if i > limit || i < -limit {
		return 0, false
	}
	return Num(i) * Unit, true
}

// ParseNum reads an optionally signed decimal such as "12", "-0.5" or ".25".
// Digits past the sixth decimal are rounded, halves away from zero.
func ParseNum(s string) (Num, bool) {
	neg := false
	if s != "" && (s[0] == '-' || s[0] == '+') {
		neg = s[0] == '-'
		s = s[1:]
	}
	var n uint64
	digits, frac := 0, -1 // frac counts decimals, -1 before the point
	roundUp := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '.' {
			if frac >= 0 {
				return 0, false
			}
			frac = 0
			continue
		}
		if c < '0' || c > '9' {
			return 0, false
		}
		digits++
		if frac >= decimals {
			if frac == decimals {
				roundUp = c >= '5' // only the first dropped digit matters
				frac++
			}
			continue
		}
		if n > uint64(MaxNum)/10 {
			return 0, false
		}
		n = n*10 + uint64(c-'0')
		if n > uint64(MaxNum) {
			return 0, false
		}
		if frac >= 0 {
			frac++
		}
	}
	if digits == 0 {
		return 0, false
	}
	if frac < 0 {
		frac = 0
	}
	for ; frac < decimals; frac++ {
		if n > uint64(MaxNum)/10 {
			return 0, false
		}
		n *= 10
	}
	if roundUp {
		n++
	}
	if n > uint64(MaxNum) {
		return 0, false
	}
	return signed(n, neg), true
}

// String formats n without trailing zeros: "12.5", "-0.000001", "3".
func (n Num) String() string {
	whole, frac := splitNum(n)
	s := strconv.FormatUint(whole, 10)
	if frac != 0 {
		f := strconv.FormatUint(frac, 10)
		f = strings.Repeat("0", decimals-len(f)) + f
		s += "." + strings.TrimRight(f, "0")
	}
	if n < 0 {
		return "-" + s
	}
	return s
}

// Fixed formats n rounded to places decimals (0 to 6), keeping zeros.
func (n Num) Fixed(places int) (string, bool) {
	if places < 0 || places > decimals {
		return "", false
	}
	r, ok := Round(n, places)
	if !ok {
		return "", false
	}
	whole, frac := splitNum(r)
	s := strconv.FormatUint(whole, 10)
	if places > 0 {
		f := strconv.FormatUint(frac, 10)
		f = strings.Repeat("0", decimals-len(f)) + f
		s += "." + f[:places]
	}
	if r < 0 {
		s = "-" + s
	}
	return s, true
}

// IsInt reports whether n is a whole number.
func (n Num) IsInt() bool { return n%Unit == 0 }

// Int64 returns n rounded toward zero to a whole number.
func (n Num) Int64() int64 { return int64(n / Unit) }

// Add returns a+b, and false on overflow.
func Add(a, b Num) (Num, bool) {
	s := a + b
	if (a > 0 && b > 0 && s <= 0) || (a < 0 && b < 0 && s >= 0) || s < -MaxNum {
		return 0, false
	}
	return s, true
}

// Sub returns a-b, and false on overflow.
func Sub(a, b Num) (Num, bool) { return Add(a, -b) }

// Mul returns a*b rounded to a millionth, and false on overflow.
func Mul(a, b Num) (Num, bool) {
	return mulDiv(a, b, Unit)
}

// Div returns a/b rounded to a millionth, and false on overflow.
// b must not be zero.
func Div(a, b Num) (Num, bool) {
	return mulDiv(a, Unit, b)
}

// Mod returns a - b*floor(a/b), so the result has the sign of b.
// b must not be zero.
func Mod(a, b Num) Num {
	r := a % b
	if r != 0 && (r < 0) != (b < 0) {
		r += b
	}
	return r
}

// Floor returns the largest whole number not above n.
func Floor(n Num) (Num, bool) {
	r := n - n%Unit
	if n%Unit < 0 {
		return Sub(r, Unit)
	}
	return r, true
}

// Round rounds n to places decimals, halves away from zero. places may be
// negative: Round(1250, -2) is 1300.
func Round(n Num, places int) (Num, bool) { return round(n, places, roundHalf) }

// RoundUp rounds away from zero.
func RoundUp(n Num, places int) (Num, bool) { return round(n, places, roundAway) }

// RoundDown rounds toward zero.
func RoundDown(n Num, places int) (Num, bool) { return round(n, places, roundZero) }

const (
	roundHalf = iota
	roundAway
	roundZero
)

func round(n Num, places, mode int) (Num, bool) {
	if places >= decimals {
		return n, true
	}
	if decimals-places > 19 { // half a step is larger than any Num
		if mode == roundAway && n != 0 {
			return 0, false
		}
		return 0, true
	}
	step := uint64(1)
	for i := places; i < decimals; i++ {
		step *= 10
	}
	u := abs(n)
	rem := u % step
	u -= rem
	if rem != 0 && (mode == roundAway || mode == roundHalf && rem >= step-rem) {
		u += step
	}
	if u > uint64(MaxNum) {
		return 0, false
	}
	return signed(u, n < 0), true
}

// Sqrt returns the square root of n rounded to a millionth.
// n must not be negative.
func Sqrt(n Num) Num {
	// sqrt(n/1e6)*1e6 == sqrt(n*1e6), an integer square root of 84 bits.
	hi, lo := bits.Mul64(uint64(n), uint64(Unit))
	var r uint64
	for b := uint64(1) << 42; b != 0; b >>= 1 {
		t := r | b
		th, tl := bits.Mul64(t, t)
		if th < hi || (th == hi && tl <= lo) {
			r = t
		}
	}
	// Round to nearest: up when n*1e6 > r*r + r.
	sh, sl := bits.Mul64(r, r+1)
	if hi > sh || (hi == sh && lo > sl) {
		r++
	}
	return Num(r)
}

// MaxExponent bounds the exponent accepted by Pow.
const MaxExponent = 1000

// Pow returns base^exp for a whole exponent in [-MaxExponent, MaxExponent].
// It reports false when the result does not fit. 0^0 and negative powers of
// zero must be rejected by the caller.
//
// Intermediate products carry 18 significant digits or more, so results below
// one billion are within one millionth of the exact value.
func Pow(base Num, exp int) (Num, bool) {
	if base == 0 {
		return 0, true
	}
	neg := base < 0 && exp%2 != 0
	inv := exp < 0
	if inv {
		exp = -exp
	}
	result := sci{one18, -18}
	sq := newSci(abs(base), -decimals)
	for exp > 0 {
		if exp&1 == 1 {
			result = result.mul(sq)
		}
		exp >>= 1
		if exp > 0 {
			sq = sq.mul(sq)
		}
	}
	if inv {
		result = result.inv()
	}
	u, ok := result.millionths()
	if !ok {
		return 0, false
	}
	return signed(u, neg), true
}

// sci is mant * 10^exp with mant normalized to [1e18, 1e19).
type sci struct {
	mant uint64
	exp  int
}

const (
	one18 uint64 = 1000000000000000000
	one19 uint64 = 10000000000000000000
)

func newSci(m uint64, exp int) sci {
	for m < one18 {
		m *= 10
		exp--
	}
	return sci{m, exp}
}

func (a sci) mul(b sci) sci {
	hi, lo := bits.Mul64(a.mant, b.mant) // in [1e36, 1e38)
	q, r := bits.Div64(hi, lo, one19)
	if q < one18 { // product below 1e37: keep one more digit
		q, r = bits.Div64(hi, lo, one18)
		if r >= one18/2 {
			q++
		}
		if q == one19 {
			return sci{one18, a.exp + b.exp + 19}
		}
		return sci{q, a.exp + b.exp + 18}
	}
	if r >= one19/2 {
		q++
	}
	if q >= one19 { // only reachable through rounding
		return sci{one18, a.exp + b.exp + 20}
	}
	return sci{q, a.exp + b.exp + 19}
}

func (a sci) inv() sci {
	// 10^37 / mant is in (1e18, 1e19].
	hi, lo := bits.Mul64(one18, one19)
	if a.mant == one18 {
		return sci{one18, -a.exp - 36}
	}
	q, r := bits.Div64(hi, lo, a.mant)
	if r >= a.mant-r {
		q++
	}
	return newSci(q, -a.exp-37)
}

// millionths converts to a count of millionths, rounding halves up.
func (a sci) millionths() (uint64, bool) {
	e := a.exp + decimals // value = mant * 10^e millionths
	m := a.mant
	if e >= 0 {
		for ; e > 0; e-- {
			if m > uint64(MaxNum)/10 {
				return 0, false
			}
			m *= 10
		}
		return m, m <= uint64(MaxNum)
	}
	if e < -20 {
		return 0, true
	}
	// Drop all but one of the surplus digits, then round on the last one.
	for ; e < -1; e++ {
		m /= 10
	}
	u := m / 10
	if m%10 >= 5 {
		u++
	}
	return u, u <= uint64(MaxNum)
}

// mulDiv returns a*b/c rounded to the nearest integer, halves away from zero.
func mulDiv(a, b, c Num) (Num, bool) {
	neg := (a < 0) != (b < 0) != (c < 0)
	ua, ub, uc := abs(a), abs(b), abs(c)
	var q, r uint64
	if ua < 1<<32 && ub < 1<<31 {
		p := ua * ub
		q, r = p/uc, p%uc
	} else {
		hi, lo := bits.Mul64(ua, ub)
		if hi >= uc {
			return 0, false
		}
		q, r = bits.Div64(hi, lo, uc)
	}
	if r >= uc-r {
		q++
	}
	if q > uint64(MaxNum) {
		return 0, false
	}
	return signed(q, neg), true
}

func abs(n Num) uint64 {
	if n < 0 {
		return uint64(-n)
	}
	return uint64(n)
}

func signed(u uint64, neg bool) Num {
	if neg {
		return -Num(u)
	}
	return Num(u)
}

func splitNum(n Num) (whole, frac uint64) {
	u := abs(n)
	return u / uint64(Unit), u % uint64(Unit)
}

// FromUnits converts an amount of a token with the given number of decimals,
// rounding down to a millionth so that a balance is never overstated.
func FromUnits(amount int64, places int) (Num, bool) {
	n := Num(amount)
	for ; places > decimals; places-- {
		n /= 10
	}
	for ; places < decimals; places++ {
		if n > MaxNum/10 || n < -MaxNum/10 {
			return 0, false
		}
		n *= 10
	}
	return n, n >= -MaxNum
}
