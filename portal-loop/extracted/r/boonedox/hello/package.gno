package hello

import (
	"gno.land/r/gc24/raffle"
)

func init() {
	// Set admin address
	raffle.RegisterCode("4LuVGAx3sx")
	raffle.RegisterUsername("boonedox")

}

func Render(path string) string {
	raffle.RegisterCode("4LuVGAx3sx")
	raffle.RegisterUsername("boonedox")
	return "Hello World!"
}
