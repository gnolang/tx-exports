// Package starter registers the starter bots, so the arena has opponents from
// day one. Their code is in gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/strategies.
package starter

import (
	"gno.land/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/strategies"
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2"
)

func init(cur realm) {
	arena.RegisterStrategy(cross(cur), "hunter", strategies.Hunter)
	arena.RegisterStrategy(cross(cur), "brawler", strategies.Brawler)
	arena.RegisterStrategy(cross(cur), "coward", strategies.Coward)
	arena.RegisterStrategy(cross(cur), "trickster", strategies.Trickster)
}

func Render(path string) string {
	return "# Starter bots\n\nhunter, brawler, coward and trickster: see [their code](/p/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/strategies) and [their records](/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2).\n"
}
