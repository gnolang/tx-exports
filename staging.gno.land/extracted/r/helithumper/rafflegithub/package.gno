package rafflegithub

import (
	"gno.land/r/gc24/raffle"
)

func init() {
	// code := "uW9zngjSwE"
	githubAcct := "helithumper"
	// _ = raffle.RegisterCode(code)
	_ = raffle.RegisterUsername(githubAcct)
}
