package raffle

import (
	"gno.land/r/gc24/raffle"
)

const code = "FmJ4gDUiCc"
const username = "ian-howell"

func init() {
	raffle.RegisterCode(code)
	raffle.RegisterUsername(username)
}

func Render(path string) string {
	return "Hello World!"
}
