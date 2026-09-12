package oracle

import "math/overflow"

// MedianInt64 returns the median of xs. The input is not mutated.
// Even length: floor average of the two central values.
func MedianInt64(xs []int64) int64 {
	n := len(xs)
	if n == 0 {
		panic("oracle: empty median")
	}
	ys := make([]int64, n)
	copy(ys, xs)
	for i := 1; i < n; i++ {
		v := ys[i]
		j := i
		for j > 0 && ys[j-1] > v {
			ys[j] = ys[j-1]
			j--
		}
		ys[j] = v
	}
	if n%2 == 1 {
		return ys[n/2]
	}
	sum, ok := overflow.Add64(ys[n/2-1], ys[n/2])
	if !ok {
		panic("oracle: median overflow")
	}
	mid, ok := overflow.Div64(sum, 2)
	if !ok {
		panic("oracle: median overflow")
	}
	return mid
}
