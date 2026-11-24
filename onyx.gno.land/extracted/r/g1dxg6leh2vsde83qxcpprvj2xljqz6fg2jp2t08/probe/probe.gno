// Package probe measures how long a package waits for approval on Onyx.
package probe

import "strconv"

var (
	count int
	last  address
)

// Bump increments the counter, remembers the caller and returns the new count.
func Bump(cur realm) int {
	count++
	last = cur.Previous().Address()
	return count
}

func Render(path string) string {
	s := "# probe\n\nCounter: " + strconv.Itoa(count) + "\n"
	if last != "" {
		s += "\nLast caller: " + last.String() + "\n"
	}
	return s
}
