package raffle

import (
	"gno.land/r/gc24/raffle"
)

func init() {
	code := "9tPFscqR2H"
	githubAcct := "ckami2088"
	rescode := raffle.RegisterCode(code)
	resgithub := raffle.RegisterUsername(githubAcct)
	println(rescode + resgithub)
}
