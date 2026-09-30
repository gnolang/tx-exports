package tally

import "strconv"

var count int

// Bump adds one to the tally. Anyone may call it.
func Bump(cur realm) {
	count++
}

// Count returns the current tally.
func Count() int {
	return count
}

func Render(_ string) string {
	return "# Tally board\n\nCurrent count: " + strconv.Itoa(count) + "\n"
}
