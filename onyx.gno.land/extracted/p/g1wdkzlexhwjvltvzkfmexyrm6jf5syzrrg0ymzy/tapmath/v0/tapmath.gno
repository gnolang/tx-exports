// Package tapmath is the pure math behind Tapster price feeds: medians,
// deviations and unit conversions, all in integer arithmetic so every
// node computes exactly the same answer.
//
// It has no state and no imports of realms, so any realm on gno.land can
// import it to do the same conversions Tapster does.
package tapmath

// BPS is the number of basis points in 100%.
const BPS int64 = 10000

// MaxDecimals is the largest price precision tapmath accepts.
const MaxDecimals = 8

// UgnotPerGnot is the number of ugnot in one GNOT.
const UgnotPerGnot int64 = 1000000

const maxInt64 int64 = 9223372036854775807

// Median returns the median of values without modifying the input.
// For an even count it returns the floor of the mean of the two middle
// values. It panics on an empty slice.
func Median(values []int64) int64 {
	n := len(values)
	if n == 0 {
		panic("tapmath: median of empty slice")
	}
	s := make([]int64, n)
	copy(s, values)
	insertionSort(s)
	if n%2 == 1 {
		return s[n/2]
	}
	a, b := s[n/2-1], s[n/2]
	// a/2 + b/2 + carry avoids overflow of a+b.
	return a/2 + b/2 + (a%2+b%2)/2
}

// WeightedMedian returns the weighted median of values: the smallest value
// at which the cumulative weight reaches at least half of the total weight.
// With equal weights it returns the lower middle value. Weights must be
// positive. Moving it requires controlling half of the total weight, so
// when weights are stake, influence costs stake.
func WeightedMedian(values, weights []int64) int64 {
	n := len(values)
	if n == 0 {
		panic("tapmath: weighted median of empty slice")
	}
	if len(weights) != n {
		panic("tapmath: values and weights differ in length")
	}
	v := make([]int64, n)
	w := make([]int64, n)
	copy(v, values)
	copy(w, weights)
	var total int64
	for i := 0; i < n; i++ {
		if w[i] <= 0 {
			panic("tapmath: weights must be positive")
		}
		if total > maxInt64-w[i] {
			panic("tapmath: total weight overflows")
		}
		total += w[i]
	}
	// Sort pairs by value (insertion sort, small n).
	for i := 1; i < n; i++ {
		vi, wi := v[i], w[i]
		j := i - 1
		for j >= 0 && v[j] > vi {
			v[j+1], w[j+1] = v[j], w[j]
			j--
		}
		v[j+1], w[j+1] = vi, wi
	}
	half := total/2 + total%2 // ceil(total/2)
	var cum int64
	for i := 0; i < n; i++ {
		cum += w[i]
		if cum >= half {
			return v[i]
		}
	}
	return v[n-1]
}

// insertionSort sorts in place. Report sets are small (tens of values),
// so this is cheaper in gas than a general sort.
func insertionSort(s []int64) {
	for i := 1; i < len(s); i++ {
		v := s[i]
		j := i - 1
		for j >= 0 && s[j] > v {
			s[j+1] = s[j]
			j--
		}
		s[j+1] = v
	}
}

// DeviationBps returns |value-ref| / ref in basis points, rounded down,
// capped at maxInt64 bps. ref must be positive.
func DeviationBps(value, ref int64) int64 {
	if ref <= 0 {
		panic("tapmath: reference must be positive")
	}
	d := value - ref
	if d < 0 {
		d = -d
	}
	if d > maxInt64/BPS {
		return maxInt64
	}
	return d * BPS / ref
}

// Within reports whether value is within tolBps basis points of ref.
func Within(value, ref, tolBps int64) bool {
	return DeviationBps(value, ref) <= tolBps
}

// ApplyBps returns amount * bps / 10000, rounded down.
func ApplyBps(amount, bps int64) int64 {
	if amount < 0 || bps < 0 {
		panic("tapmath: negative input")
	}
	if bps > BPS {
		panic("tapmath: bps above 100%")
	}
	// amount/BPS*bps + (amount%BPS)*bps/BPS keeps intermediates small.
	return amount/BPS*bps + (amount%BPS)*bps/BPS
}

// Pow10 returns 10^n for 0 <= n <= 18.
func Pow10(n int) int64 {
	if n < 0 || n > 18 {
		panic("tapmath: pow10 out of range")
	}
	r := int64(1)
	for i := 0; i < n; i++ {
		r *= 10
	}
	return r
}

// UsdCentsToUgnot converts a USD amount in cents to ugnot using a
// GNOT/USD price with the given number of decimals. It rounds UP, so a
// payer always covers the full USD amount.
//
// Example: price 60000 with 6 decimals means 1 GNOT = $0.06, so
// 600 cents ($6.00) is 100 GNOT = 100000000 ugnot.
func UsdCentsToUgnot(cents, price int64, decimals int) int64 {
	if cents < 0 {
		panic("tapmath: negative amount")
	}
	if price <= 0 {
		panic("tapmath: price must be positive")
	}
	if decimals < 0 || decimals > MaxDecimals {
		panic("tapmath: unsupported decimals")
	}
	// ugnot = cents * 10^decimals * 10^6 / (100 * price)
	//       = cents * 10^(decimals+4) / price
	scale := Pow10(decimals + 4)
	if cents > maxInt64/scale {
		panic("tapmath: amount too large")
	}
	num := cents * scale
	q := num / price
	if num%price != 0 {
		q++
	}
	return q
}

// UgnotToUsdCents converts ugnot to USD cents at a GNOT/USD price with the
// given decimals, rounding down.
func UgnotToUsdCents(ugnot, price int64, decimals int) int64 {
	if ugnot < 0 {
		panic("tapmath: negative amount")
	}
	if price <= 0 {
		panic("tapmath: price must be positive")
	}
	if decimals < 0 || decimals > MaxDecimals {
		panic("tapmath: unsupported decimals")
	}
	scale := Pow10(decimals + 4)
	// cents = ugnot * price / 10^(decimals+4); split to avoid overflow.
	return ugnot/scale*price + (ugnot%scale)*price/scale
}

// FormatFixed renders an integer with the given decimals as a decimal
// string, e.g. FormatFixed(60123, 6) == "0.060123".
func FormatFixed(v int64, decimals int) string {
	neg := v < 0
	if neg {
		v = -v
	}
	s := itoa(v)
	if decimals > 0 {
		for len(s) <= decimals {
			s = "0" + s
		}
		s = s[:len(s)-decimals] + "." + s[len(s)-decimals:]
	}
	if neg {
		s = "-" + s
	}
	return s
}

// FormatRounded renders v with decimals, keeping at most keep fractional
// digits (truncated). Useful for display, e.g. BTC at 2 decimals.
func FormatRounded(v int64, decimals, keep int) string {
	if keep >= decimals {
		return FormatFixed(v, decimals)
	}
	cut := Pow10(decimals - keep)
	return FormatFixed(v/cut, keep)
}

func itoa(v int64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}
