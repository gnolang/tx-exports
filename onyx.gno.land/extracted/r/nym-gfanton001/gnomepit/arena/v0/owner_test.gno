package arena

import (
	"testing"

	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/nym-gfanton001/gnomepit/standings/v0"
)

// Under gno test, init's deployer address is empty, so each test sets the owner itself.

func TestRetireIsOwnerOnly(cur realm, t *testing.T) {
	reset()
	owner = ownable.NewWithAddress(alice)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "ownable: caller is not owner", func() { Retire(cross(cur)) })
	uassert.AbortsWithMessage(t, cur, "ownable: caller is not owner", func() { TransferOwnership(cross(cur), bob) })
	uassert.False(t, Retired())
	uassert.Equal(t, alice, Owner())

	testing.SetRealm(testing.NewUserRealm(alice))
	Retire(cross(cur))
	uassert.True(t, Retired())
	TransferOwnership(cross(cur), bob)
	uassert.Equal(t, bob, Owner())
}

func TestRetiredArenaRefusesNewMatches(cur realm, t *testing.T) {
	reset()
	owner = ownable.NewWithAddress(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	Retire(cross(cur))

	uassert.AbortsWithMessage(t, cur, "arena retired", func() {
		Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "arena retired", func() { Accept(cross(cur), id, "Ironhide", deckB, braces) })
}

func TestRetiredArenaFinishesItsMatches(cur realm, t *testing.T) {
	reset()
	owner = ownable.NewWithAddress(alice)
	a1, b1 := "Chalk Dust,Double Tap", "Hammer Blow,Spiked Shield"
	testing.SetRealm(testing.NewUserRealm(alice))
	open := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	running := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, a1), boxOf("box1"), "")
	stalled := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), running, "Ironhide", deckB, b1)
	Accept(cross(cur), stalled, "Ironhide", deckB, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), running, deckA, saltA, a1, salt1, sealOf(salt2, picks), boxOf("box2"))
	Retire(cross(cur))

	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), running, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), running, "", "", picks, salt2, sealOf(salt3, picks), boxOf("box3"))
	uassert.Equal(t, "play", Match(running).Phase)
	testing.SetRealm(testing.NewUserRealm(bob))
	Resign(cross(cur), running)
	uassert.Equal(t, "resign", Match(running).Reason)

	testing.SkipHeights(day + 1)
	testing.SetRealm(testing.NewUserRealm(carol))
	ClaimForfeit(cross(cur), stalled)
	uassert.Equal(t, "forfeit", Match(stalled).Reason)

	testing.SetRealm(testing.NewUserRealm(alice))
	Resign(cross(cur), open)
	uassert.Equal(t, 0, len(Open(0, 50)), "the open challenge is withdrawn")
}

func TestRetiredArenaStillRates(cur realm, t *testing.T) {
	reset()
	owner = ownable.NewWithAddress(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Retire(cross(cur))

	before := standings.ResultCount()
	testing.SetRealm(testing.NewUserRealm(bob))
	Resign(cross(cur), id)
	uassert.Equal(t, before+1, standings.ResultCount())
}
