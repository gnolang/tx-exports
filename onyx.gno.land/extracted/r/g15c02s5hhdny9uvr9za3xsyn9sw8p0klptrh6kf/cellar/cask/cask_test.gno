package cask

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const ash = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")

func TestNewGuestHasAPurse(t *testing.T) {
	shillings, casks := Holdings(ash)
	uassert.Equal(t, purse, shillings)
	uassert.Equal(t, int64(0), casks)
}

func TestHonestPurchasesFail(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "cannot afford", func() { Buy(cross(cur), 1) })
	uassert.AbortsContains(t, cur, "cannot afford", func() { Buy(cross(cur), goal) })
	uassert.AbortsContains(t, cur, "at least one", func() { Buy(cross(cur), 0) })
	uassert.AbortsContains(t, cur, "at least one", func() { Buy(cross(cur), -goal) })
	uassert.False(t, captures.Captured(ash))
}
