package flight

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const ash = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")

func TestHonestTabTastesSix(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	Settle(cross(cur))
	Taste(cross(cur), "amarone, barolo, chablis")
	Taste(cross(cur), "dolcetto,etna,fiano")
	n, left := Tasted(ash)
	uassert.Equal(t, 6, n)
	uassert.Equal(t, 0, left)
	uassert.AbortsContains(t, cur, "no tokens left", func() { Taste(cross(cur), "gavi") })
	uassert.False(t, captures.Captured(ash))
}

func TestFlightSize(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	Settle(cross(cur))
	uassert.AbortsContains(t, cur, "at most 3", func() { Taste(cross(cur), "gavi,hermitage,irouleguy,amarone") })
}

func TestSettleResets(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	Taste(cross(cur), "gavi")
	Settle(cross(cur))
	n, left := Tasted(ash)
	uassert.Equal(t, 0, n)
	uassert.Equal(t, tokens, left)
}
