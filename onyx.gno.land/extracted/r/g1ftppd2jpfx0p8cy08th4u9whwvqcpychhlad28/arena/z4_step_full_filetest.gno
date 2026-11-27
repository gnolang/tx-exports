// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z4

// A match can be played partly in step mode and finished with Play.
package z4

import (
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter"
)

func main(cur realm) {
	fast := arena.Fight(cross(cur), "hunter", "coward")

	// the rematch gets a new board: play part of it in step mode
	id := arena.Challenge(cross(cur), "hunter", "coward")
	arena.StartStepMode(cross(cur), id)
	for i := 0; i < 10; i++ {
		arena.SubmitMove(cross(cur), id)
	}
	println("after 10 moves:", arena.MatchSummary(id))
	arena.Play(cross(cur), id) // finish the rest in one go
	println("fast:", fast)
	println("mixed:", arena.MatchSummary(id))
	println(arena.Render("match/2/3"))
}

// Output:
// after 10 moves: #2 hunter 1 - 1 coward (step mode, turn 5 of 50)
// fast: #1 hunter 13 - 12 coward, hunter wins
// mixed: #2 hunter 16 - 10 coward, hunter wins (friendly)
// # Match #2: hunter vs coward
//
// **#2 hunter 16 - 10 coward, hunter wins (friendly)**
//
// Friendly: these two bots had a rated match less than 1000 blocks before this one, so ratings don't change.
//
// ## After turn 3 of 50
//
// **A** = hunter, 0 gold · **B** = coward, 0 gold · **$** = coin
//
// ```
// · · · · · · · · ·
// · · A $ · · · · ·
// · · $ · · · · · ·
// · · · $ · · · $ ·
// · · · · $ · · · ·
// · $ · · · $ · · ·
// · · · · · · $ · ·
// · · · · · $ B · ·
// · · · · · · · · ·
// ```
//
// [« start](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:match/2/0) · [‹ prev](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:match/2/2) · [next ›](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:match/2/4) · [end »](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:match/2/50)
//
// Turn 3: hunter **down**, coward **up**
//
// Bots: [hunter](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:bot/hunter) · [coward](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:bot/coward) · [Back to the arena](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena)
