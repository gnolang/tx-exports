package panicvictim

import "strconv"

var value = 0

func SetAndPanic(v int) {
	value = v
	panic("deliberate panic after state write")
}

func Render(_ string) string { return strconv.Itoa(value) }
