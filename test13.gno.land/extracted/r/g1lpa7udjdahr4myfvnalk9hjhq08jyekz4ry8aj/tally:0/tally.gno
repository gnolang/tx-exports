package tally

import "fmt"

var count int

// Bump increments the counter by one.
func Bump() {
	count++
}

func Render(_ string) string {
	return fmt.Sprintf("# Tally Board\n\nCount: **%d**", count)
}
