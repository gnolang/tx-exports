package gopher

import (
	"gno.land/r/gc24/raffle"
)

const raffleCode = "eFAwFHEHrU"

func init() {
	result := raffle.RegisterCode(raffleCode)

	fmt.Println(result)

	result = raffle.RegisterUsername("ja-howell")

	fmt.Println(result)
}

func Render(path string) string {
	return "Hello World!"
}
