// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z3

// Step mode pins the crash on the realm bot that causes it: its move can't be
// submitted, the deadline passes, and anyone can claim the forfeit.
package z3

import (
	"testing"

	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter/v2"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots/crasher"
)

func main(cur realm) {
	id := arena.Challenge(cross(cur), "brawler", "realm-crasher")
	arena.StartStepMode(cross(cur), id)
	for i := 0; i < 200; i++ {
		r := revive(func() { arena.SubmitMove(cross(cur), id) })
		if r != nil {
			println("move failed:", r)
			break
		}
	}
	println(arena.MatchSummary(id))

	r := revive(func() { arena.ClaimForfeit(cross(cur), id) })
	println("early claim:", r)

	testing.SkipHeights(arena.MoveTimeout + 1)
	println(arena.ClaimForfeit(cross(cur), id))
	info, _ := arena.GetBot("realm-crasher")
	println("losses:", info.Losses, "forfeits:", info.Forfeits)
	println(arena.Render("match/1"))
}

// Output:
// move failed: realm bot crashes on purpose
// #1 brawler 2 - 3 realm-crasher (step mode, turn 9 of 50)
// early claim: realm-crasher still has until block 223 to move
// #1 brawler wins by forfeit: realm-crasher missed its move deadline on turn 10
// losses: 1 forfeits: 1
// # Match #1: brawler vs realm-crasher
//
// **#1 brawler wins by forfeit: realm-crasher missed its move deadline on turn 10**
//
// Rating change: brawler +16, realm-crasher -16
//
// ## After turn 9 of 50
//
// **A** = brawler, 2 gold · **B** = realm-crasher, 3 gold · **$** = coin
//
// ```
// · · $ · · · · · ·
// · · · · · · · · ·
// · · · · · · · · ·
// · · · · A $ $ · ·
// · · · · B · · · ·
// · · $ $ · · · · ·
// · · · · · · · · ·
// · · · · · · · · ·
// · · · · · · $ · ·
// ```
//
// [« start](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:match/1/0) · [‹ prev](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:match/1/8)
//
// Turn 9: brawler **attack** (stole a coin), realm-crasher **attack** (stole a coin)
//
// ## Key moments
//
// - [Turn 9](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:match/1/9): brawler stole a coin from realm-crasher
// - [Turn 9](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:match/1/9): realm-crasher stole a coin from brawler
//
// Bots: [brawler](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:bot/brawler) · [realm-crasher](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:bot/realm-crasher) · [Back to the arena](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2)
