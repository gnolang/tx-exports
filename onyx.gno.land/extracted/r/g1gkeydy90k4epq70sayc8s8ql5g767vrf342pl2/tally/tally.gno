package tally

import "strconv"

var count int

// Bump adds one to the tally and returns the new count. Anyone may call it.
func Bump(cur realm) int {
	count++
	return count
}

// Render shows the current count.
func Render(path string) string {
	return "# Tally board\n\nCount: " + strconv.Itoa(count) + "\n"
}
