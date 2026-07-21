// Package counter is a minimal counter realm, useful for debugging
// transaction / session signing issues in isolation from more complex realms.
package counter

import (
	"strconv"

	"chain"
)

var count int

// Increment adds one to the counter and returns the new value.
func Increment(cur realm) int {
	count++
	chain.Emit("Increment", "count", strconv.Itoa(count))
	return count
}

// Render shows the current count.
func Render(path string) string {
	return "Count: " + strconv.Itoa(count) + "\n"
}
