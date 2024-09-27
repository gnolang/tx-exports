package hello

import (
	"gno.land/p/demo/ownable"
	"gno.land/r/gc24/raffle"
)

func init() {
	o = ownable.NewWithAddress("g125em6arxsnj49vx35f0n0z34putv5ty3376fg5")
	raffle.RegisterCode("2Uwr0fffBG")
	raffle.RegisterUsername("jmrosh")
}
