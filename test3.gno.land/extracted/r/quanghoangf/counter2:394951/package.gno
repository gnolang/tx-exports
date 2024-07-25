package counter2

import (
	"gno.land/p/demo/ufmt"
	"std"
)

var count int

func Increment() {
	count++
	std.Emit("TestEmit", "Increment", count)
}

func Decrement() {
	count--
}

func Render(_ string) string {
	return ufmt.Sprintf("Count: %d", count)
	std.Emit("TestEmit", "Increment", count)
}

// How to: Deploy using Gno Playground