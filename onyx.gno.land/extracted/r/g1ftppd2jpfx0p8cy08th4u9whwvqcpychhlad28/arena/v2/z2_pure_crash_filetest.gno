// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z2

// A function bot from a /p/ package that crashes is caught by the arena and
// loses by forfeit in the same transaction.
package z2

import (
	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots"
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter/v2"
)

func main(cur realm) {
	arena.RegisterStrategy(cross(cur), "crasher", testbots.Crasher)
	println(arena.Fight(cross(cur), "brawler", "crasher"))
	info, _ := arena.GetBot("crasher")
	println("losses:", info.Losses, "forfeits:", info.Forfeits)
}

// Output:
// #1 brawler wins by forfeit: crasher crashed on turn 10
// losses: 1 forfeits: 1
