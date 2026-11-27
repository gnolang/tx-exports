package rack

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const ash = address("g1zkzjmyveh7euq83h5zhnhj6mg0d7kr35nphzd2")

func TestOnlyKeeperReserves(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "only the keeper", func() { Reserve(cross(cur), ash, Prize) })
}

func TestKeeperNeverReservesThePrize(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(Ledger.Keeper))
	uassert.AbortsContains(t, cur, "would never", func() { Reserve(cross(cur), ash, Prize) })
}

func TestOrdinaryBottleIsNotTheFlag(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(Ledger.Keeper))
	Reserve(cross(cur), ash, "1990 Barolo")
	testing.SetRealm(testing.NewUserRealm(ash))
	uassert.AbortsContains(t, cur, "not the flag", func() { Collect(cross(cur)) })
	uassert.False(t, captures.Captured(ash))
}
