package median

import (
	"gno.land/p/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/fixedpoint"
)

// Median returns the median of a slice of int64 values.
// Panics on empty input. Does not mutate the input slice.
func Median(values []int64) int64 {
	n := len(values)
	if n == 0 {
		panic("median: empty slice")
	}
	sorted := make([]int64, n)
	copy(sorted, values)
	sortInt64(sorted)

	if n%2 == 1 {
		return sorted[n/2]
	}
	a := sorted[n/2-1]
	b := sorted[n/2]
	return (a + b) / 2
}

// MedianOfFixed returns the median of a slice of Fixed values.
func MedianOfFixed(values []fixedpoint.Fixed) fixedpoint.Fixed {
	n := len(values)
	if n == 0 {
		panic("median: empty slice")
	}
	sorted := make([]fixedpoint.Fixed, n)
	copy(sorted, values)
	sortFixed(sorted)

	if n%2 == 1 {
		return sorted[n/2]
	}
	a := sorted[n/2-1]
	b := sorted[n/2]
	return a.Add(b).Div(fixedpoint.FromInt(2))
}

func Min(values []int64) int64 {
	if len(values) == 0 {
		panic("median: empty slice")
	}
	m := values[0]
	for _, v := range values[1:] {
		if v < m {
			m = v
		}
	}
	return m
}

func Max(values []int64) int64 {
	if len(values) == 0 {
		panic("median: empty slice")
	}
	m := values[0]
	for _, v := range values[1:] {
		if v > m {
			m = v
		}
	}
	return m
}

func sortInt64(s []int64) {
	for i := 1; i < len(s); i++ {
		key := s[i]
		j := i - 1
		for j >= 0 && s[j] > key {
			s[j+1] = s[j]
			j--
		}
		s[j+1] = key
	}
}

func sortFixed(s []fixedpoint.Fixed) {
	for i := 1; i < len(s); i++ {
		key := s[i]
		j := i - 1
		for j >= 0 && s[j].Cmp(key) > 0 {
			s[j+1] = s[j]
			j--
		}
		s[j+1] = key
	}
}
