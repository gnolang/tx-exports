package raffle

import (
	"gno.land/r/gc24/raffle"
)

// Somewhat similar to Go, init() executes upon deployment of your code.
// Hint: maybe you can use init() in your code to execute RegisterCode() upon deployment via play.gno.land?
func init() {
	// Set admin address

	_ = raffle.RegisterCode("EeoVgGAwDN")
	_ = raffle.RegisterUsername("bigzoo")
}
