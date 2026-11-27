package livery

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const ash = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")

func TestNoLiveryNoEntry(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "guests in livery only", func() { Enter(cross(cur)) })
}

func TestWardrobeRefusesOthers(t *testing.T) {
	uassert.PanicsContains(t, nil, "only the steward", func() { Dress(ash) })
	uassert.False(t, InLivery(ash))
}
