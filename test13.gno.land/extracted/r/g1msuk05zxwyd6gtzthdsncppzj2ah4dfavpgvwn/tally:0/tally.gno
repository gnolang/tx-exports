package tally

import "strconv"

var count int

// Bump increments the tally by one.
func Bump() {
	count++
}

func Render(_ string) string {
	return "# Tally Board\n\nCount: **" + strconv.Itoa(count) + "**"
}
