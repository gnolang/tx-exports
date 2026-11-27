package rfentry2

import (
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfkt/rfbotp"
	"gno.land/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfkt/rfarena"
	"gno.land/r/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfkt/rfbotr"
)

var Last string

func Duel(cur realm) string {
	a := rfarena.Register(cross(cur), rfbotp.Move)
	b := rfarena.Register(cross(cur), rfbotr.Move)
	Last = rfarena.Duel(cross(cur), a, b, 32, 32, 2000)
	return Last
}

func PPanic(cur realm) string {
	a := rfarena.Register(cross(cur), rfbotp.Move)
	b := rfarena.Register(cross(cur), rfbotp.Panicky)
	Last = rfarena.SafeDuel(cross(cur), a, b)
	return Last
}

func RPanic(cur realm) string {
	a := rfarena.Register(cross(cur), rfbotp.Move)
	b := rfarena.Register(cross(cur), rfbotr.Panicky)
	Last = rfarena.SafeDuel(cross(cur), a, b)
	return Last
}

func Render(path string) string { return "last: " + Last }

func RegP(cur realm) int { return rfarena.Register(cross(cur), rfbotp.Move) }

func RegR(cur realm) int { return rfarena.Register(cross(cur), rfbotr.Move) }

func Plain(cur realm) string { Last = "plain ok"; return Last }
