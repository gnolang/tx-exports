// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z5

// A bot can't change the board through its copy of it, invalid moves count
// as staying put, and registration rules are enforced.
package z5

import (
	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots"
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter"
)

func main(cur realm) {
	arena.RegisterStrategy(cross(cur), "tamper", testbots.Tamper)
	arena.RegisterStrategy(cross(cur), "garbage", testbots.Garbage)
	println(arena.Fight(cross(cur), "tamper", "hunter"))
	println(arena.Fight(cross(cur), "garbage", "hunter"))

	try := func(name string, f func()) { println(name+":", revive(f)) }
	try("duplicate", func() { arena.RegisterStrategy(cross(cur), "hunter", testbots.Idle) })
	try("bad name", func() { arena.RegisterStrategy(cross(cur), "Bad Name", testbots.Idle) })
	try("self fight", func() { arena.Fight(cross(cur), "hunter", "hunter") })
	try("unknown", func() { arena.Fight(cross(cur), "hunter", "nobody") })
	arena.RegisterStrategy(cross(cur), "idle-1", testbots.Idle)
	arena.RegisterStrategy(cross(cur), "idle-2", testbots.Idle)
	arena.RegisterStrategy(cross(cur), "idle-3", testbots.Idle)
	try("sixth bot", func() { arena.RegisterStrategy(cross(cur), "idle-4", testbots.Idle) })
	try("submit on pending", func() { arena.SubmitMove(cross(cur), 1) })
	try("replay finished", func() { arena.Play(cross(cur), 1) })
}

// Output:
// #1 tamper 0 - 23 hunter, hunter wins
// #2 garbage 0 - 20 hunter, hunter wins
// duplicate: bot name already taken: hunter
// bad name: bot names may only use a-z, 0-9 and inner dashes
// self fight: a bot can't fight itself
// unknown: unknown bot: nobody
// sixth bot: this realm already registered the maximum number of bots
// submit on pending: match is not in step mode
// replay finished: match already finished
