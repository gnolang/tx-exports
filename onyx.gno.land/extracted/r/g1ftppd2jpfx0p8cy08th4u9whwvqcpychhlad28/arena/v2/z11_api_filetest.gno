// PKGPATH: gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/z11

// The read API returns JSON that apps can query for free.
package z11

import (
	"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/arena/v2"
	_ "gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter/v2"
)

func main(cur realm) {
	arena.Fight(cross(cur), "hunter", "trickster")
	println(arena.ArenaJSON())
	println(arena.BotJSON("trickster"))
	println(arena.MatchesJSON("", 5))
	m := arena.MatchJSON(1)
	println(len(m) > 1000, m[:400])
	println(arena.TournamentsJSON(), arena.SeasonsJSON())
}

// Output:
// {"bots":6,"matches":1,"tournaments":0,"season":1,"seasonStart":123,"seasonEnds":720123,"height":123,"seasonLength":720000,"moveTimeout":100,"ratedCooldown":1000,"boardSize":9,"turns":50}
// {"name":"trickster","realm":"gno.land/r/g1ftppd2jpfx0p8cy08th4u9whwvqcpychhlad28/bots/starter/v2","owner":"","kind":"function","description":"","version":1,"retired":false,"rating":1216,"seasonWins":1,"seasonLosses":0,"seasonDraws":0,"wins":1,"losses":0,"draws":0,"forfeits":0,"registered":123,"previousVersions":[]}
// [{"id":1,"a":"hunter","b":"trickster","status":"finished","turn":50,"goldA":1,"goldB":10,"winner":1,"forfeit":false,"reason":"","rated":true,"delta":-16,"season":1,"tournament":0,"created":123,"settled":123,"summary":"#1 hunter 1 - 10 trickster, trickster wins"}]
// true {"id":1,"a":"hunter","b":"trickster","status":"finished","turn":50,"goldA":1,"goldB":10,"winner":1,"forfeit":false,"reason":"","rated":true,"delta":-16,"season":1,"tournament":0,"created":123,"settled":123,"summary":"#1 hunter 1 - 10 trickster, trickster wins","seed":735905,"frames":[{"turn":0,"pos":[[0,0],[8,8]],"gold":[0,0],"actions":["stay","stay"],"stole":[false,false],"parried":[false,false],
// [] []
