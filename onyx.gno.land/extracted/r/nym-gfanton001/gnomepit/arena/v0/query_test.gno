package arena

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func summaryIDs(list []MatchSummary) string {
	var out []string
	for _, s := range list {
		out = append(out, s.ID)
	}
	return strings.Join(out, ",")
}

func TestWithdraw(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "not your challenge", func() { Resign(cross(cur), id) })

	testing.SetRealm(testing.NewUserRealm(alice))
	Resign(cross(cur), id)
	uassert.PanicsWithMessage(t, nil, "unknown match", func() { Match(id) })
	uassert.Equal(t, 0, len(Matches(alice, 0, 50)))
	uassert.Equal(t, "[]", showIDs(loadPlayer(alice).ids))
	uassert.Equal(t, 0, len(Open(0, 50)))
	uassert.AbortsWithMessage(t, cur, "unknown match", func() { Resign(cross(cur), id) })
}

func TestWithdrawExpired(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SkipHeights(7*day + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "not your challenge", func() { Resign(cross(cur), id) })

	testing.SetRealm(testing.NewUserRealm(alice))
	Resign(cross(cur), id)
	uassert.PanicsWithMessage(t, nil, "unknown match", func() { Match(id) })
	uassert.Equal(t, 0, len(Matches(alice, 0, 50)))
	uassert.Equal(t, "[]", showIDs(loadPlayer(alice).ids))
	uassert.Equal(t, "", openList)
}

func TestResign(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, picks, salt1, sealOf(salt2, picks), boxOf("box2"))

	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "not a player", func() { Resign(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(bob))
	Resign(cross(cur), id)

	v := Match(id)
	uassert.Equal(t, phaseEnded, v.Phase)
	uassert.Equal(t, "a", v.Result)
	uassert.Equal(t, "resign", v.Reason)
	uassert.Equal(t, "", v.ToMove)
	uassert.Equal(t, 1, v.Round)
}

func TestClaimForfeitInReveal(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "wrong phase", func() { ClaimForfeit(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)

	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsWithMessage(t, cur, "deadline not passed", func() { ClaimForfeit(cross(cur), id) })
	testing.SkipHeights(day + 1)
	ClaimForfeit(cross(cur), id)

	v := Match(id)
	uassert.Equal(t, "b", v.Result)
	uassert.Equal(t, "forfeit", v.Reason)
	uassert.False(t, v.DeadlinePassed)
}

func TestClaimForfeitInPlay(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, picks, salt1, sealOf(salt2, picks), boxOf("box2"))
	testing.SkipHeights(day + 1)
	ClaimForfeit(cross(cur), id)

	v := Match(id)
	uassert.Equal(t, "a", v.Result)
	uassert.Equal(t, "forfeit", v.Reason)
}

func TestMatchesNewestFirst(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	seal := sealOf(saltA, deckA)
	Challenge(cross(cur), "Pickers", seal, sealOf(salt1, picks), boxOf("box1"), "")
	id := Challenge(cross(cur), "Pickers", seal, sealOf(salt1, picks), boxOf("box1"), "")
	Challenge(cross(cur), "Pickers", seal, sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)

	uassert.Equal(t, "3,2,1", summaryIDs(Matches(alice, 0, 50)))
	uassert.Equal(t, "2", summaryIDs(Matches(alice, 1, 1)))
	uassert.Equal(t, "2", summaryIDs(Matches(bob, 0, 50)))
	uassert.Equal(t, 0, len(Matches(carol, 0, 50)))

	s := Matches(bob, 0, 50)[0]
	uassert.Equal(t, phaseReveal, s.Phase)
	uassert.Equal(t, 1, s.Round)
	uassert.Equal(t, alice.String(), s.Challenger)
	uassert.Equal(t, bob.String(), s.Acceptor)
	uassert.Equal(t, "Pickers", s.ChallengerClan)
	uassert.Equal(t, "Ironhide", s.AcceptorClan)
	uassert.Equal(t, alice.String(), s.ToMove)

	open := Matches(alice, 0, 50)[0]
	uassert.Equal(t, phaseOpen, open.Phase)
	uassert.Equal(t, "", open.ToMove)
	uassert.Equal(t, Open(0, 1)[0].Expires, open.Deadline)
}

func TestMatchViewKeepsTheSealHidden(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)

	v := Match(id)
	uassert.Equal(t, "", v.Opponent)
	uassert.Equal(t, "", v.ChallengerDeck)
	uassert.Equal(t, deckB, v.AcceptorDeck)
	urequire.Equal(t, 1, len(v.Plans))
	uassert.Equal(t, "", v.Plans[0][0])
	uassert.Equal(t, braces, v.Plans[0][1])
	uassert.Equal(t, boxOf("box1"), v.Box)
	uassert.Equal(t, 0, len(v.HP))

	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, picks, salt1, sealOf(salt2, picks), boxOf("box2"))
	v = Match(id)
	want := resolveAll([2]string{picks, braces})
	uassert.Equal(t, phasePlay, v.Phase)
	uassert.Equal(t, 2, v.Round)
	uassert.Equal(t, bob.String(), v.ToMove)
	uassert.Equal(t, deckA, v.ChallengerDeck)
	urequire.Equal(t, 2, len(v.Plans))
	uassert.Equal(t, picks, v.Plans[0][0])
	uassert.Equal(t, "", v.Plans[1][0])
	uassert.Equal(t, "", v.Plans[1][1])
	uassert.Equal(t, boxOf("box2"), v.Box)
	urequire.Equal(t, 1, len(v.HP))
	uassert.Equal(t, want.State.Gnomes[0].HP, v.HP[0][0])
	uassert.Equal(t, want.State.Gnomes[1].HP, v.HP[0][1])

	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), id, braces)
	v = Match(id)
	uassert.Equal(t, "", v.Plans[1][0])
	uassert.Equal(t, braces, v.Plans[1][1])
	uassert.Equal(t, alice.String(), v.ToMove)
}

func TestMatchViewDeadlinePassed(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	uassert.False(t, Match(id).DeadlinePassed)
	testing.SkipHeights(day + 1)
	uassert.True(t, Match(id).DeadlinePassed)
}

func TestMatchViewExpired(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SkipHeights(7*day + 1)
	uassert.Equal(t, phaseExpired, Match(id).Phase)
}

func TestUnknownMatch(t *testing.T) {
	reset()
	uassert.PanicsWithMessage(t, nil, "unknown match", func() { Match("99") })
	uassert.PanicsWithMessage(t, nil, "unknown match", func() { Match("12345678901") })
	uassert.PanicsWithMessage(t, nil, "unknown match", func() { Match("") })
}

// Only an id's own decimal text names its match.
func TestMatchIDsAreExact(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	uassert.Equal(t, "1", Match(id).ID)
	for _, other := range []string{"01", "+1", "-1", " 1", "1 ", "0", "1.0", "0x1", "0000000001"} {
		uassert.PanicsWithMessage(t, nil, "unknown match", func() { Match(other) }, other)
		uassert.AbortsWithMessage(t, cur, "unknown match", func() { Resign(cross(cur), other) }, other)
		uassert.True(t, strings.Contains(Render("match/"+other), "Not found"), other)
	}
}
