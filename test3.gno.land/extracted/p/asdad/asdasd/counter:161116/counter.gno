package counter

import "ufmt"

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
