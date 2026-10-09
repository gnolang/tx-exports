// Package ledger is gnosplit's arithmetic: amounts in cents, how an expense
// is split, and the fewest transfers that settle a group. It holds no state,
// so a later gnosplit release and an app can reuse it as is.
package ledger

import (
	"strconv"
	"strings"
)

// MaxCents bounds one amount: 100 million units of a currency. With rates
// up to MaxRate the products below stay far inside int64.
const MaxCents int64 = 10_000_000_000

// MaxRate bounds a conversion rate, in millionths: 1,000,000 units for one.
const MaxRate int64 = 1_000_000_000_000

// ParseCents reads a positive amount written "42", "42.5" or "42,50": digits,
// then at most one "." or "," and two decimals. Thousands separators are
// refused, since "1,234" would read as 1.234.
func ParseCents(s string) (int64, bool) {
	n, ok := parseDecimal(s, 2)
	if !ok || n <= 0 || n > MaxCents {
		return 0, false
	}
	return n, true
}

// ParseRate reads a positive rate with up to six decimals, in millionths.
func ParseRate(s string) (int64, bool) {
	n, ok := parseDecimal(s, 6)
	if !ok || n <= 0 || n > MaxRate {
		return 0, false
	}
	return n, true
}

// ParseAmount reads an amount in the group's currency ("42.50"), or a foreign
// one with its rate ("50 USD x0.92": 50 dollars at 0.92 each). note is the
// foreign amount as typed, cleaned up, and "" for a plain one.
func ParseAmount(s string) (cents int64, note string, ok bool) {
	f := strings.Fields(s)
	switch {
	case len(f) == 1:
		cents, ok = ParseCents(f[0])
		return cents, "", ok
	case len(f) == 3 && len(f[2]) > 1 && (f[2][0] == 'x' || f[2][0] == 'X'):
		orig, ok1 := ParseCents(f[0])
		rate, ok2 := ParseRate(f[2][1:])
		code := strings.ToUpper(f[1])
		if !ok1 || !ok2 || !validCode(code) {
			return 0, "", false
		}
		cents = Convert(orig, rate)
		if cents <= 0 || cents > MaxCents {
			return 0, "", false
		}
		return cents, Format(orig) + " " + code + " × " + formatRate(rate), true
	}
	return 0, "", false
}

// Convert turns cents into cents of another currency at rate (millionths),
// rounding half up. It splits the rate so no product overflows.
func Convert(cents, rate int64) int64 {
	q, r := rate/1_000_000, rate%1_000_000
	return cents*q + (cents*r+500_000)/1_000_000
}

// Format writes cents as "1,234.56", "-12.00" or "0.00".
func Format(cents int64) string {
	sign := ""
	if cents < 0 {
		sign, cents = "-", -cents
	}
	units := strconv.FormatInt(cents/100, 10)
	for i := len(units) - 3; i > 0; i -= 3 {
		units = units[:i] + "," + units[i:]
	}
	frac := cents % 100
	if frac < 10 {
		return sign + units + ".0" + strconv.FormatInt(frac, 10)
	}
	return sign + units + "." + strconv.FormatInt(frac, 10)
}

// Signed is Format with a "+" on positive amounts, for balances.
func Signed(cents int64) string {
	if cents > 0 {
		return "+" + Format(cents)
	}
	return Format(cents)
}

func parseDecimal(s string, places int) (int64, bool) {
	s = strings.TrimSpace(s)
	if len(s) == 0 || len(s) > 24 {
		return 0, false
	}
	var n int64
	digits, frac := 0, -1 // frac counts decimals once the separator is seen
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= '0' && c <= '9':
			if frac >= 0 {
				if frac == places {
					return 0, false
				}
				frac++
			}
			digits++
			n = n*10 + int64(c-'0')
			if n > 1_000_000_000_000_000 {
				return 0, false
			}
		case (c == '.' || c == ',') && frac < 0 && digits > 0:
			frac = 0
		default:
			return 0, false
		}
	}
	if frac == 0 { // "12." has a separator and no decimal
		return 0, false
	}
	if frac < 0 {
		frac = 0
	}
	for ; frac < places; frac++ {
		if n > 1_000_000_000_000_000 {
			return 0, false
		}
		n *= 10
	}
	return n, true
}

func validCode(c string) bool {
	if len(c) < 1 || len(c) > 5 {
		return false
	}
	for i := 0; i < len(c); i++ {
		if c[i] < 'A' || c[i] > 'Z' {
			return false
		}
	}
	return true
}

// formatRate writes millionths without trailing zeros: 920000 is "0.92".
func formatRate(r int64) string {
	s := strconv.FormatInt(r/1_000_000, 10)
	frac := strconv.FormatInt(1_000_000+r%1_000_000, 10)[1:]
	frac = strings.TrimRight(frac, "0")
	if frac == "" {
		return s
	}
	return s + "." + frac
}
