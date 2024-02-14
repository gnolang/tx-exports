package demo

import (
	"std"

	"gno.land/p/grc/grc20"
)

// Slashcoin is public and mintable. Inherit grc20.IGRC20
var Slashcoin grc20.IGRC20

func init() {
	// generate minter and mint some tokens to test1.
	const test1 = std.Address("g1ah79e3txw2kd2e8dscr2y2ucr888lm3qwm3v6e")
	minter := grc20.NewAdminToken("Slashcoin", "SLASH", 18)
	minter.Mint(test1, 1000000)

	// publicly expose an unprivileged implementation of IGRC20.
	Slashcoin = minter.GRC20()
}

