package tally

import "strconv"

var count int

// Bump increments the tally by one and returns the new count.
func Bump(cur realm) int {
	count++
	return count
}

// Count returns the current tally.
func Count() int {
	return count
}

func Render(path string) string {
	return "# Tally board\n\nCurrent count: " + strconv.Itoa(count) + "\n"
}
