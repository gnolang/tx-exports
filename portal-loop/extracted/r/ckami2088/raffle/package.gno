package rafflegithub

import (
	"gno.land/r/gc24/raffle"
)

func init() {
	code := "9tPFscqR2H"
	githubAcct := "ckami2088"
	_ = raffle.RegisterCode(code)
	_ = raffle.RegisterUsername(githubAcct)
}
