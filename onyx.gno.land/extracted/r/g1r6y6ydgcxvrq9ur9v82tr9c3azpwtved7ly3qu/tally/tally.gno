// Package tally is a public tally board: anyone can bump the counter.
package tally

import "strconv"

var count int

// Bump increments the tally by one.
func Bump(cur realm) {
	count++
}

// Count returns the current tally.
func Count() int {
	return count
}

// Render shows the current tally.
func Render(path string) string {
	return "# Tally board\n\nCurrent count: " + strconv.Itoa(count) + "\n"
}
