package counter

import (
	"std"
	"gno.land/p/demo/ufmt"
)

var count int

func Increment() {
	count++
	std.Emit("TestEmit", "Increment", count)
}

func Decrement() {
	count--
	std.Emit("TestEmit", "Decrement", count)
}

func Render(_ string) string {
	return ufmt.Sprintf("Count: %d", count)
}

// How to: Deploy using Gno Playground