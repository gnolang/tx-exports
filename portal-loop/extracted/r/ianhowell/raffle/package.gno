package raffle

import (
	"gno.land/r/gc24/raffle"
)

const code = "FmJ4gDUiCc"
const username = "ian-howell"

func init() {
	result := raffle.RegisterCode(code)
	fmt.Printf("Result: %v\n", result)

	result = raffle.RegisterUsername(username)
	fmt.Printf("Result: %v\n", result)
}

func Render(path string) string {
	return "Hello World!"
}
