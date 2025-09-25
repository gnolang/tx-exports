package goraffle

import "gno.land/r/gc24/raffle"

func Register(code string) {
	println(raffle.RegisterCode(code))
}

func Render(path string) string {
	return "Hello World!"
}
