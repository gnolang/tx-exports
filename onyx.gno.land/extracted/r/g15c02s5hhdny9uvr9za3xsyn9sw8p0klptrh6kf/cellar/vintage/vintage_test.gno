package vintage

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const ash = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")

func TestHouseWineIsTooYoung(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "is young", func() { Appraise(cross(cur), Uncork()) })
	uassert.AbortsContains(t, cur, "needs a bottle", func() { Appraise(cross(cur), nil) })
	uassert.False(t, captures.Captured(ash))
}

func TestUncork(t *testing.T) {
	b := Uncork()
	uassert.Equal(t, 2024, b.Vintage())
	uassert.Equal(t, "House red", b.Label())
}
