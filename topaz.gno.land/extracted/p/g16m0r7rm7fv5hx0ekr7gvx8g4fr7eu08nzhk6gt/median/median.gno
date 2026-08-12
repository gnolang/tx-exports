// Package median computes the median (and min/max) of a set of int64
// values -- the standard building block for price-feed and oracle-style
// realms that aggregate several independent submissions and want a
// result that isn't skewed by a single bad or malicious outlier, unlike
// a plain average.
package median

import (
	"gno.land/p/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/fixedpoint"
)

// Median returns the median of values. Panics on an empty slice -- there
// is no meaningful median of nothing. For an even-length input, returns
// the integer-divided average of the two middle values (deterministic,
// no fractional precision loss concerns since this is int64 math).
// Does not mutate the caller's slice.
func Median(values []int64) int64 {
	if len(values) == 0 {
		panic("median: cannot compute median of an empty slice")
	}

	sorted := sortedCopy(values)
	n := len(sorted)
	if n%2 == 1 {
		return sorted[n/2]
	}
	return (sorted[n/2-1] + sorted[n/2]) / 2
}

// MedianOfFixed is the same computation over fixedpoint.Fixed values,
// operating on their Raw representation so the result stays exact
// (no float ever enters the picture).
func MedianOfFixed(values []fixedpoint.Fixed) fixedpoint.Fixed {
	if len(values) == 0 {
		panic("median: cannot compute median of an empty slice")
	}

	raws := make([]int64, len(values))
	for i, v := range values {
		raws[i] = v.Raw
	}
	return fixedpoint.FromRaw(Median(raws))
}

// Min returns the smallest value. Panics on an empty slice.
func Min(values []int64) int64 {
	if len(values) == 0 {
		panic("median: cannot compute min of an empty slice")
	}
	m := values[0]
	for _, v := range values[1:] {
		if v < m {
			m = v
		}
	}
	return m
}

// Max returns the largest value. Panics on an empty slice.
func Max(values []int64) int64 {
	if len(values) == 0 {
		panic("median: cannot compute max of an empty slice")
	}
	m := values[0]
	for _, v := range values[1:] {
		if v > m {
			m = v
		}
	}
	return m
}

// sortedCopy returns a sorted ascending copy of values, leaving the
// input untouched. Plain insertion sort -- realistic inputs here are a
// handful of oracle/reporter submissions, not large datasets, so O(n^2)
// is the right tradeoff over pulling in a general-purpose sort.
func sortedCopy(values []int64) []int64 {
	out := make([]int64, len(values))
	copy(out, values)

	for i := 1; i < len(out); i++ {
		key := out[i]
		j := i - 1
		for j >= 0 && out[j] > key {
			out[j+1] = out[j]
			j--
		}
		out[j+1] = key
	}
	return out
}
