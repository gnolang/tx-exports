package main

import (
	"gno.land/r/gc24/raffle"
)

func TacoBell(code string, username string) {
	raffle.RegisterCode(code)
	raffle.RegisterUsername(username)
}

func init() {
	TacoBell("MZkDw5z7g8", "nprimmer")
}
