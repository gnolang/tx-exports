package arena

import (
	"gno.land/p/nym-gfanton001/gnomepit/engine/v0"
	"gno.land/r/nym-gfanton001/gnomepit/standings/v0"
)

// report sends match m, which has just ended, to the standings realm to be rated. A match
// its challenger accepted is not reported. Neither is any match while the arena is off the
// writer list, where Record would abort the ending.
func report(cur realm, rules *engine.Ruleset, m record) {
	if m.challenger == m.acceptor || !standings.IsWriter(self) {
		return
	}
	standings.Record(cross(cur), m.challenger, m.acceptor, clanName(rules, m.clans[0]), clanName(rules, m.clans[1]), m.result)
}
