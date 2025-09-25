package raffle

import (
	"gno.land/r/gc24/raffle"
)

func init() {
	code := "efX8UmKBy6"
	githubAcct := "whoagain"
	rescode := raffle.RegisterCode(code)
	resgithub := raffle.RegisterUsername(githubAcct)
	println(rescode + resgithub)
}
