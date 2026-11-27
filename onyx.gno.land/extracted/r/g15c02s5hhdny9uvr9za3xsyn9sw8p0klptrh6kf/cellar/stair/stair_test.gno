package stair

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const ash = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")

func TestOnlyHeadStewardAppoints(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "only the head steward", func() { Appoint(cross(cur), ash) })
	uassert.False(t, IsSteward(ash))
}

func TestStrangersCannotDescend(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "does not know you", func() { Descend(cross(cur)) })
}

func TestAppointedStewardDescends(cur realm, t *testing.T) {
	friend := address("g1rh0vd3xzwjpcqehrf0tpjlqeq35079wf4zklar")
	testing.SetRealm(testing.NewUserRealm(headSteward))
	Appoint(cross(cur), friend)
	testing.SetRealm(testing.NewUserRealm(friend))
	Descend(cross(cur))
	uassert.True(t, captures.Captured(friend))
}
