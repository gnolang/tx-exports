package main

import (
	"gno.land/r/gc24/raffle"
)

func TacoBell(input string) {
	raffle.RegisterCode(input)
}

func init() {
	TacoBell("MZkDw5z7g8")
}
