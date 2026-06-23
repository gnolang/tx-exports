package tally

import "strconv"

var count int

// Bump increments the tally by one. Anyone may call it.
func Bump(cur realm) {
	count++
}

// Count returns the current tally.
func Count() int {
	return count
}

func Render(_ string) string {
	return "## Tally Board\n\nCount: " + strconv.Itoa(count)
}
