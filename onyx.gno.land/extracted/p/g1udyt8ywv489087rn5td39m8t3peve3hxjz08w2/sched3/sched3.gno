package sched3

import (
	"strconv"
	"strings"
)

// Seed builds the activation seed for a circle.
func Seed(circleID uint64, height int64, members []string) string {
	parts := make([]string, len(members))
	copy(parts, members)
	sortStrings(parts)
	return strconv.FormatUint(circleID, 10) + "|" + strconv.FormatInt(height, 10) + "|" + strings.Join(parts, ",")
}

// Order returns a deterministic permutation of 0..n-1 for the given seed.
func Order(n int, seed string) []int {
	idx := make([]int, n)
	for i := 0; i < n; i++ {
		idx[i] = i
	}
	if n < 2 {
		return idx
	}
	h := fnv(seed)
	for i := n - 1; i > 0; i-- {
		h = h*1099511628211 + 12345
		j := int((h >> 13) % uint64(i+1))
		idx[i], idx[j] = idx[j], idx[i]
	}
	return idx
}

func fnv(s string) uint64 {
	var h uint64 = 14695981039346656037
	for i := 0; i < len(s); i++ {
		h ^= uint64(s[i])
		h *= 1099511628211
	}
	return h
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}
