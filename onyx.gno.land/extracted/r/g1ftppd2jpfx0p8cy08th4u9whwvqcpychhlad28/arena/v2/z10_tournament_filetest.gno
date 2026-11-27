// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z10

// A round-robin tournament with a bot that crashes: the crash is handled by
// step mode and a forfeit, and the tournament still finishes.
package z10

import (
	"testing"

	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2"
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots/crasher"
)

func main(cur realm) {
	try := func(name string, f func()) { println(name+":", revive(f)) }
	// act as a wallet: calls from this test now arrive as calls from its owner
	testing.SetOriginCaller(cur.Address())
	crasher.RegisterHunter(cross(cur), "t-hunter")
	crasher.RegisterTrickster(cross(cur), "t-trickster")
	crasher.Register(cross(cur), "t-crasher")

	id := arena.CreateTournament(cross(cur), "Friday Night <Brawl>", 4)
	for _, b := range []string{"t-hunter", "t-trickster", "t-crasher"} {
		arena.JoinTournament(cross(cur), id, b)
	}
	try("join twice", func() { arena.JoinTournament(cross(cur), id, "t-hunter") })
	try("play before start", func() { arena.PlayTournament(cross(cur), id) })
	arena.StartTournament(cross(cur), id)
	try("join after start", func() { arena.JoinTournament(cross(cur), id, "t-hunter") })

	for i := 0; i < 6; i++ {
		a, b, ok := arena.TournamentNext(id)
		if !ok {
			break
		}
		if a != "t-crasher" && b != "t-crasher" {
			println("played:", arena.PlayTournament(cross(cur), id))
			continue
		}
		// t-crasher would cancel a one-transaction match: create the match,
		// then play it in step mode until its move fails.
		mid := arena.NextTournamentMatch(cross(cur), id)
		arena.StartStepMode(cross(cur), mid)
		for j := 0; j < 200; j++ {
			if revive(func() { arena.SubmitMove(cross(cur), mid) }) != nil {
				break
			}
		}
		testing.SkipHeights(arena.MoveTimeout + 1)
		println("forfeit:", arena.ClaimForfeit(cross(cur), mid))
	}
	try("play after the end", func() { arena.PlayTournament(cross(cur), id) })
	println(arena.Render("tournament/1"))
}

// Output:
// join twice: t-hunter is already entered
// play before start: tournament is open for entries
// join after start: tournament is not open for entries
// forfeit: #1 t-trickster wins by forfeit: t-crasher missed its move deadline on turn 10
// forfeit: #2 t-hunter wins by forfeit: t-crasher missed its move deadline on turn 10
// played: #3 t-hunter 10 - 16 t-trickster, t-trickster wins
// play after the end: tournament is finished
// # Tournament #1: Friday Night Brawl
//
// **finished** · 3/4 bots · created by `g1hurj7dkh03kd0ezwj2fktpmua023xgv4ya9crn`
//
// **Winner: [t-trickster](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:bot/t-trickster)**
//
// ## Table
//
// | # | Bot | P | W | D | L | Gold | Pts |
// |---|---|---|---|---|---|---|---|
// | 1 | [t-trickster](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:bot/t-trickster) | 2 | 2 | 0 | 0 | 18:11 | **6** |
// | 2 | [t-hunter](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:bot/t-hunter) | 2 | 1 | 0 | 1 | 15:20 | **3** |
// | 3 | [t-crasher](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:bot/t-crasher) | 2 | 0 | 0 | 2 | 5:7 | **0** |
//
// ## Schedule
//
// 1. [#1 t-trickster wins by forfeit: t-crasher missed its move deadline on turn 10](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:match/1)
// 2. [#2 t-hunter wins by forfeit: t-crasher missed its move deadline on turn 10](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:match/2)
// 3. [#3 t-hunter 10 - 16 t-trickster, t-trickster wins](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:match/3)
//
// [All tournaments](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:tournaments) · [Back to the arena](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2)
