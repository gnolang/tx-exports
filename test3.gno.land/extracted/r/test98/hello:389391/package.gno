package hello

var s = 0

func Add() int {
	s++
	return s
}

func Render(path string) string {
	return "Hello World!"
}
