package raffle

import (
	"gno.land/r/gc24/raffle"
)

func init() {
	code := "WNiFC2DTs7"
	githubAcct := "ally-lee"
	rescode := raffle.RegisterCode(code)
	resgithub := raffle.RegisterUsername(githubAcct)
	println(rescode + resgithub)
}
