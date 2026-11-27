// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z9

// A season ends after SeasonLength blocks: its top 10 is archived and
// ratings and season records reset, while all-time records stay.
package z9

import (
	"testing"

	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter/v2"
)

func main(cur realm) {
	println(arena.Fight(cross(cur), "hunter", "brawler"))
	println(arena.Fight(cross(cur), "trickster", "coward"))
	n, end := arena.SeasonInfo()
	println("season", n)

	testing.SkipHeights(arena.SeasonLength + 5)
	println(arena.Fight(cross(cur), "hunter", "trickster"))
	n2, end2 := arena.SeasonInfo()
	println("season", n2, "ended where expected:", end2 == end+arena.SeasonLength)
	for _, s := range arena.PastSeason(1) {
		println("season 1:", s.Bot, s.Rating, s.Wins, s.Losses, s.Draws)
	}
	info, _ := arena.GetBot("brawler")
	println("brawler now:", info.Rating, "all-time losses:", info.Losses)
	println(arena.Render("seasons"))
}

// Output:
// #1 hunter 0 - 3 brawler, brawler wins
// #2 trickster 13 - 12 coward, trickster wins
// season 1
// #3 hunter 4 - 18 trickster, trickster wins
// season 2 ended where expected: true
// season 1: brawler 1216 1 0 0
// season 1: trickster 1216 1 0 0
// season 1: coward 1184 0 1 0
// season 1: hunter 1184 0 1 0
// brawler now: 1200 all-time losses: 0
// # Seasons
//
// Season 2 is running. Ends at block 1440123 (about 29 days). Ratings reset each season; the top 10 is kept. [Past seasons](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:seasons)
//
// ## Season 1
//
// | # | Bot | Elo | W-L-D |
// |---|---|---|---|
// | 1 | [brawler](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:bot/brawler) | 1216 | 1-0-0 |
// | 2 | [trickster](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:bot/trickster) | 1216 | 1-0-0 |
// | 3 | [coward](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:bot/coward) | 1184 | 0-1-0 |
// | 4 | [hunter](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2:bot/hunter) | 1184 | 0-1-0 |
//
// [Back to the arena](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2)
