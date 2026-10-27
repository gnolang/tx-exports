// Package counter is the smallest realm that still proves the whole pipeline:
// it is deployed, approved, called with an int and a string, read back through
// Render and through QEval, and made to abort on purpose.
//
// It imports nothing but strconv, deliberately. A smoke test that fails because
// a stdlib package moved between chain versions reports a problem with itself,
// not with the chain, and that is the one failure mode this file must not have.
package counter

import "strconv"

var (
	count int
	note  string
)

// Increment adds n and returns the new total. It panics on a non-positive n,
// which is what the scenario's expect_fail step exercises: a realm that aborts
// is a different outcome from one that is unreachable, and only a real chain
// tells the two apart.
func Increment(cur realm, n int) int {
	if n <= 0 {
		panic("increment must be positive")
	}
	count += n
	return count
}

// SetNote stores a short string, so the scenario covers a string argument
// surviving the round trip through amino and back out of Render.
func SetNote(cur realm, s string) {
	if len(s) > 64 {
		panic("note too long")
	}
	note = s
}

// Get is the QEval target: an int return, read with no gas and no key.
func Get() int { return count }

func Render(path string) string {
	if path == "note" {
		return "note: " + note
	}
	return "count: " + strconv.Itoa(count)
}
