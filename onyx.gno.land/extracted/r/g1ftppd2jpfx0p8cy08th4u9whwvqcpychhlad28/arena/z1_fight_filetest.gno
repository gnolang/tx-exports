// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z1

// Starter bots and the realm bot with memory fight each other; results,
// ratings and pages are recorded.
package z1

import (
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/reader"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter"
)

func main(cur realm) {
	println(arena.Fight(cross(cur), "hunter", "brawler"))
	println(arena.Fight(cross(cur), "reader", "coward"))
	println(arena.Fight(cross(cur), "brawler", "reader"))
	println(arena.Fight(cross(cur), "hunter", "brawler")) // new board for the rematch
	info, _ := arena.GetBot("hunter")
	println("hunter rating:", info.Rating, "played:", info.Played)
	println(arena.Render(""))
}

// Output:
// #1 hunter 0 - 3 brawler, brawler wins
// #2 reader 12 - 13 coward, coward wins
// #3 brawler 0 - 11 reader, reader wins
// #4 hunter 8 - 2 brawler, hunter wins (friendly)
// hunter rating: 1184 played: 2
// # Code Arena
//
// Bots are realms. Deploy one, register it, and the chain referees every match by calling each bot's code turn by turn. Every bot's source is public, so you can study a rival before you challenge it.
//
// **6 bots** · **4 matches** · [Start a fight](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena$help&func=Fight&a=&b=)
//
// ## Leaderboard
//
// | # | Bot | Elo | W-L-D | |
// |---|---|---|---|---|
// | 1 | [coward](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:bot/coward) | 1216 | 1-0-0 | [code](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter$source) · [fight](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena$help&func=Fight&a=&b=coward) |
// | 2 | [reader](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:bot/reader) | 1201 | 1-1-0 | [code](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/reader$source) · [fight](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena$help&func=Fight&a=&b=reader) |
// | 3 | [realm-crasher](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:bot/realm-crasher) | 1200 | 0-0-0 | [code](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/testbots/crasher$source) · [fight](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena$help&func=Fight&a=&b=realm-crasher) |
// | 4 | [trickster](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:bot/trickster) | 1200 | 0-0-0 | [code](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter$source) · [fight](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena$help&func=Fight&a=&b=trickster) |
// | 5 | [brawler](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:bot/brawler) | 1199 | 1-2-0 | [code](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter$source) · [fight](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena$help&func=Fight&a=&b=brawler) |
// | 6 | [hunter](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:bot/hunter) | 1184 | 1-1-0 | [code](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter$source) · [fight](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena$help&func=Fight&a=&b=hunter) |
//
// ## Recent matches
//
// - [#4 hunter 8 - 2 brawler, hunter wins (friendly)](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:match/4)
// - [#3 brawler 0 - 11 reader, reader wins](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:match/3)
// - [#2 reader 12 - 13 coward, coward wins](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:match/2)
// - [#1 hunter 0 - 3 brawler, brawler wins](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena:match/1)
//
// ## Rules
//
// - 9×9 board, 50 turns. Bots start in opposite corners; coins are placed point-symmetrically, so neither corner has an advantage. A new pair of coins appears every 5 turns.
// - Each turn both bots choose at once: `Up`, `Down`, `Left`, `Right`, `Stay`, `Attack` or `Defend`.
// - Step on a coin to take it. Bots never share a square: if both step onto the same one, priority alternates each turn.
// - Next to the enemy, `Attack` steals one coin. But attacking into a `Defend` is parried, and the defender takes a coin from you instead.
// - Most gold after 50 turns wins. Ratings are Elo-style; a pair of bots plays at most one rated match every 1000 blocks, and rematches in between are friendlies.
//
// Each turn a bot sees the board, both scores, and what both bots did last turn, so a bot can learn its opponent's habits.
//
// ## Build a bot
//
// 1. Import [`gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot`](/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bot) and write a `Move(bot.State) bot.Action` method (a realm bot can keep memory) or a plain function.
// 2. Register it from your realm's `init`: `arena.RegisterBot(cross(cur), "my-bot", &myBot{})`.
// 3. [Fight](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena$help&func=Fight&a=my-bot&b=) anyone on the leaderboard.
//
// Starter bots to read and beat: [strategies](/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/strategies) · [reader](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/reader), a realm bot that learns each opponent's habits.
//
// ## No escaping a loss
//
// A crash inside a realm cancels the whole transaction, so a bot could crash on purpose to cancel a match it is losing. It doesn't work here: the match switches to step mode, one move per transaction, and a bot that can't make its move by the deadline loses by forfeit.
