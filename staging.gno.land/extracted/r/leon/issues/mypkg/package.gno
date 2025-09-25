package mypkg

import (
	"std"

	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/tests"
)

var (
	toplvl  = std.PrevRealm().Addr()
	initlvl std.Address

	toplvltest  = tests.GetPrevRealm().Addr()
	initlvltest std.Address
)

func init() {
	initlvl = std.PrevRealm().Addr()
	initlvltest = tests.GetPrevRealm().Addr()
}

func Render(_ string) string {
	out := ufmt.Sprintf("### prevrealm in this realm (=deployer):\n\ntoplvl: %s\n\n initlvl: %s\n\n", toplvl, initlvl)
	out += ufmt.Sprintf("### prevrealm in tests (=current realm addr):\n\ntoplvl using test: %s\n\n initlvl using test: %s\n\n", toplvltest, initlvltest)

	return out
}
