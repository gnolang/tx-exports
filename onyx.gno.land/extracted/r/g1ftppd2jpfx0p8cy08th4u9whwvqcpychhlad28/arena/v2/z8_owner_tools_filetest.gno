// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z8

// Owners can describe, retire and upgrade their bots; nobody else can.
// Upgrades keep the name, rating and record and must come from a new realm.
package z8

import (
	"testing"

	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter/v2"
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots/crasher"
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots/upgrader"
)

func main(cur realm) {
	try := func(name string, f func()) { println(name+":", revive(f)) }

	// someone else registers a bot
	me := cur.Address()
	testing.SetOriginCaller(address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"))
	crasher.RegisterHunter(cross(cur), "not-mine")

	// we register ours, then act as their owner, like a wallet would
	testing.SetOriginCaller(me)
	crasher.RegisterHunter(cross(cur), "my-hunter")
	crasher.Register(cross(cur), "my-crasher")

	try("retire someone else's bot", func() { arena.Retire(cross(cur), "not-mine") })

	arena.SetDescription(cross(cur), "my-hunter", "Goes for coins. <b>Attacks</b> [when](x) close!\nNo second line.")
	info, _ := arena.GetBot("my-hunter")
	println("description:", info.Description)

	arena.Retire(cross(cur), "my-hunter")
	try("fight a retired bot", func() { arena.Fight(cross(cur), "my-hunter", "coward") })
	try("retire twice", func() { arena.Retire(cross(cur), "my-hunter") })
	arena.Unretire(cross(cur), "my-hunter")
	println(arena.Fight(cross(cur), "my-hunter", "coward"))

	// my-crasher crashes on turn 10; after the upgrade it plays a full match
	upgrader.Upgrade(cross(cur), "my-crasher")
	println(arena.Fight(cross(cur), "brawler", "my-crasher"))
	info, _ = arena.GetBot("my-crasher")
	println("version:", info.Version, "played:", info.Played)
	println("realm:", info.Realm)
	try("upgrade again from the same realm", func() { upgrader.Upgrade(cross(cur), "my-crasher") })
	try("upgrade someone else's bot", func() { upgrader.Upgrade(cross(cur), "not-mine") })
	println(arena.Render("bot/my-crasher"))
}

// Output:
// retire someone else's bot: only the owner of not-mine can do this
// description: Goes for coins. bAttacks/b whenx close No second line.
// fight a retired bot: my-hunter is retired
// retire twice: my-hunter is already retired
// #1 my-hunter 14 - 12 coward, my-hunter wins
// #2 brawler 1 - 5 my-crasher, my-crasher wins
// version: 2 played: 1
// realm: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots/upgrader
// upgrade again from the same realm: the new version must live in a new realm
// upgrade someone else's bot: only the owner of not-mine can upgrade it
// # my-crasher
//
// [Challenge my-crasher](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2$help&func=Fight&a=&b=my-crasher) · [Read its code](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots/upgrader$source)
//
// - **Season 1:** Elo 1216, 1-0-0
// - **All time:** 1 wins, 0 losses (0 by forfeit), 0 draws
// - **Kind:** realm bot, version 2
// - **Realm:** `gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots/upgrader`
// - **Owner:** `g1wtwfayg7gpr0kqw7mnvwqnjjvu6fhun8xrdjal`
// - **Registered at block:** 123
// - **Earlier versions:** [v1](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots/crasher$source)
//
// ## Matches
//
// - [#2 brawler 1 - 5 my-crasher, my-crasher wins](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:match/2)
//
// Owner actions: [describe](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2$help&func=SetDescription&name=my-crasher&text=) · [retire](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2$help&func=Retire&name=my-crasher) · [enter a tournament](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:tournaments)
//
// [Back to the arena](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2)
