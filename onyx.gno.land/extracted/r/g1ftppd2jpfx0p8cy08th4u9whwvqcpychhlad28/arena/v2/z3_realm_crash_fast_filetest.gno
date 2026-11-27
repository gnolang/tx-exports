// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z3a

// A realm bot that crashes (to dodge a loss) makes the one-transaction match
// fail as a whole: Gno doesn't let the arena catch a crash in another realm.
// On chain this cancels the transaction, which is why step mode exists.
package z3a

import (
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter/v2"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots/crasher"
)

func main(cur realm) {
	println(arena.Fight(cross(cur), "brawler", "realm-crasher"))
}

// Error:
// realm bot crashes on purpose
