package gopher

import (
	"gno.land/r/gc24/raffle"
)

const raffleCode = "eFAwFHEHrU"

func init() {
	raffle.RegisterCode(raffleCode)
	raffle.RegisterUsername("ja-howell")
}

func Render(path string) string {
	return "Hello World!"
}
