package goraffle

import "gno.land/r/gc24/raffle"

func Register(code string) {
	println(raffle.RegisterCode())
}

func Render(path string) string {
	return "Hello World!"
}
