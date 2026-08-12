// Package tally is a minimal public tally board: anyone can bump the
// counter, and the current count is readable back via Render or Count.
package tally

import "strconv"

var count int

// Bump increments the shared counter by one and returns the new count.
func Bump(cur realm) int {
	count++
	return count
}

// Count returns the current tally.
func Count() int {
	return count
}

func Render(_ string) string {
	return "# Tally board\n\nCurrent count: " + strconv.Itoa(count) + "\n"
}
