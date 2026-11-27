// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z6

// One match on its own, to keep an eye on storage per match.
package z6

import (
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter/v2"
)

func main(cur realm) {
	println(arena.Fight(cross(cur), "hunter", "coward"))
}

// Output:
// #1 hunter 13 - 12 coward, hunter wins
