package corkscrew

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const ash = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")

func TestOldBottlesRefused(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "after 1900", func() { Shelve(cross(cur), 1700) })
	Shelve(cross(cur), 1955)
	uassert.AbortsContains(t, cur, "already shelved", func() { Shelve(cross(cur), 1955) })
}

func TestYoungBottleIsNotOldest(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	Shelve(cross(cur), 1990)
	uassert.AbortsContains(t, cur, "not yours", func() { Open(cross(cur)) })
	uassert.False(t, captures.Captured(ash))
	uassert.True(t, strings.Contains(Render(""), "- 1990:"))
}
