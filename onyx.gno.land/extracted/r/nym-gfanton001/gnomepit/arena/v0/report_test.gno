package arena

import (
	"testing"

	"gno.land/p/nym-gfanton001/gnomepit/engine/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
	"gno.land/r/nym-gfanton001/gnomepit/standings/v0"
)

// checkReported checks that the standings realm holds one result more than before, from this
// arena, for alice as Pickers against bob as Ironhide, ending in result. The standings realm
// keeps its state across tests, which reset cannot reach.
func checkReported(t *testing.T, before int, result string) {
	t.Helper()
	urequire.Equal(t, before+1, standings.ResultCount())
	page := standings.Results(before, 1)
	urequire.Equal(t, 1, len(page))
	r := page[0]
	uassert.Equal(t, "gno.land/r/nym-gfanton001/gnomepit/arena/v0", r.Writer)
	uassert.Equal(t, alice.String(), r.Challenger)
	uassert.Equal(t, bob.String(), r.Acceptor)
	uassert.Equal(t, "Pickers", r.ChallengerClan)
	uassert.Equal(t, "Ironhide", r.AcceptorClan)
	uassert.Equal(t, result, r.Result)
}

func TestEndingsReport(cur realm, t *testing.T) {
	// The worked match ends on HP with the challenger's last Reveal.
	reset()
	before := standings.ResultCount()
	a1, b1 := "Chalk Dust,Double Tap", "Hammer Blow,Spiked Shield"
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, a1), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, b1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, a1, salt1, sealOf(salt2, picks), boxOf("box2"))
	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), id, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, "", "", picks, salt2, sealOf(salt3, picks), boxOf("box3"))
	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), id, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, "", "", picks, salt3, "", "")
	uassert.Equal(t, "hp", Match(id).Reason)
	checkReported(t, before, Match(id).Result)

	// A knockout ends it with the second Reveal.
	reset()
	before = standings.ResultCount()
	testing.SetRealm(testing.NewUserRealm(alice))
	id = Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, "Pick,Anvil Stomp")
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, picks, salt1, sealOf(salt2, picks), boxOf("box2"))
	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), id, "Hammer Blow,Cobble Throw")
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, "", "", picks, salt2, "", "")
	uassert.Equal(t, "knockout", Match(id).Reason)
	checkReported(t, before, "b")

	// A resignation.
	reset()
	before = standings.ResultCount()
	testing.SetRealm(testing.NewUserRealm(alice))
	id = Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	Resign(cross(cur), id)
	checkReported(t, before, "a")

	// A forfeit claimed by a third wallet.
	reset()
	before = standings.ResultCount()
	testing.SetRealm(testing.NewUserRealm(alice))
	id = Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	testing.SkipHeights(day + 1)
	testing.SetRealm(testing.NewUserRealm(carol))
	ClaimForfeit(cross(cur), id)
	checkReported(t, before, "b")
}

func TestSelfAcceptedMatchUnreported(cur realm, t *testing.T) {
	reset()
	before := standings.ResultCount()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	Resign(cross(cur), id)
	uassert.Equal(t, "ended", Match(id).Phase)
	uassert.Equal(t, before, standings.ResultCount(), "a self-match is never reported")
}

// TestEveryClanNamePassesTheStore checks that the standings realm takes every clan name: one
// it refuses would abort every ending.
func TestEveryClanNamePassesTheStore(t *testing.T) {
	for _, c := range engine.ProofOfConcept().Clans {
		uassert.True(t, len(c.Name) >= 1 && len(c.Name) <= 32, c.Name)
	}
}
