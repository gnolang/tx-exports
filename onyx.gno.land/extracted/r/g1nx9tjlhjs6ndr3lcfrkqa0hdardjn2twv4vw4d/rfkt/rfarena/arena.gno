package rfarena

import (
	"strconv"

	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfkt/rfengine"
)

var bots []rfengine.Bot

func Register(cur realm, b rfengine.Bot) int {
	bots = append(bots, b)
	return len(bots) - 1
}

func Duel(cur realm, i, j, w, h, maxTurns int) string {
	r, turns, moves := rfengine.Play(bots[i], bots[j], w, h, maxTurns)
	return "result=" + strconv.Itoa(r) + " turns=" + strconv.Itoa(turns) + " len=" + strconv.Itoa(len(moves))
}

// SafeDuel tries to catch a bot panic with plain recover.
func SafeDuel(cur realm, i, j int) (out string) {
	defer func() {
		if e := recover(); e != nil {
			out = "recovered"
		}
	}()
	r, turns, _ := rfengine.Play(bots[i], bots[j], 16, 16, 300)
	return "result=" + strconv.Itoa(r) + " turns=" + strconv.Itoa(turns)
}
