// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z7

// reader keeps notes on each opponent across matches. Against hunter, which
// always attacks up close, it learns to parry.
package z7

import (
	"testing"

	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena"
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/reader"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter"
)

func main(cur realm) {
	for i := 0; i < 4; i++ {
		println(arena.Fight(cross(cur), "reader", "hunter"))
		testing.SkipHeights(arena.RatedCooldown)
	}
	println(reader.Render(""))
}

// Output:
// #1 reader 9 - 0 hunter, reader wins
// #2 reader 5 - 0 hunter, reader wins
// #3 reader 9 - 0 hunter, reader wins
// #4 reader 7 - 0 hunter, reader wins
// # reader
//
// A realm bot that learns: it notes what each opponent does up close and plays the answer. [Record](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:bot/reader)
//
// | Opponent | Attacks | Parries | Other | Reader's answer |
// |---|---|---|---|---|
// | hunter | 150 | 0 | 0 | parry |
