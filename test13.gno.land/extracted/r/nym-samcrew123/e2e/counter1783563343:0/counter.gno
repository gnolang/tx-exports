package counter

import "strconv"

type state struct{ count int }

func (s *state) inc() { s.count++ }

var counter state

func Increment() { counter.inc() }

func Render(_ string) string {
	return strconv.Itoa(counter.count)
}
