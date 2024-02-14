package counter

import "gno.land/p/demo/ufmt"

var count int

func Render(path string) string {
	return ufmt.Sprintf("Count: %d", count)
}

func Add() {
	count++
}

func Remove() {
	count--
}

