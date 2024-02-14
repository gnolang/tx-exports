package counter

import (
	"gno.land/p/demo/ufmt"
)

var count int

func Increment() {
	count++
}

func Decrement() {
	count--
}

func Count() int {
	return count
}

func Render(_ string) string {
	return ufmt.Sprintf("Count: %d", count)
}
