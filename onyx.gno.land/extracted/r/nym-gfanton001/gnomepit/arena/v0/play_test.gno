package arena

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nym-gfanton001/gnomepit/engine/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

const (
	deckA = "Pickaxe Flurry,Kneecap,Sling Stone,Dodge Roll,Chalk Dust,Double Tap,Momentum,Undermine"
	deckB = "Stone Guard,Bulwark,Hammer Blow,Cobble Throw,Spiked Shield,Anvil Stomp,Feint,Avalanche"

	salt1 = "1111111111111111111111111111111111111111111111111111111111111111"
	salt2 = "2222222222222222222222222222222222222222222222222222222222222222"
	salt3 = "3333333333333333333333333333333333333333333333333333333333333333"

	picks  = "Pick,Pick,Pick"
	braces = "Brace,Brace,Brace"

	day = 86400 / 5 // block heights in 24 hours at the test chain's 5 s per block
)

// recordOf loads match id as the realm stores it.
func recordOf(t *testing.T, id string) record {
	n, err := strconv.Atoi(id)
	urequire.NoError(t, err)
	m, ok := loadMatch(engine.ProofOfConcept(), n)
	urequire.True(t, ok, "match "+id+" is not stored")
	return m
}

// resolveAll plays rounds of [A plan, B plan] with the engine directly.
func resolveAll(rounds ...[2]string) engine.Outcome {
	rules := engine.ProofOfConcept()
	s := rules.Start()
	var o engine.Outcome
	for _, r := range rounds {
		a, _ := rules.PlanOf(strings.Split(r[0], ",")...)
		b, _ := rules.PlanOf(strings.Split(r[1], ",")...)
		o = rules.Resolve(s, a, b)
		s = o.State
	}
	return o
}

func TestWorkedExample(cur realm, t *testing.T) {
	reset()
	a1, b1 := "Chalk Dust,Double Tap", "Hammer Blow,Spiked Shield"

	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, a1), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, b1)
	uassert.Equal(t, phaseReveal, Match(id).Phase)
	uassert.Equal(t, 0, len(Open(0, 50)))

	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, a1, salt1, sealOf(salt2, picks), boxOf("box2"))
	uassert.Equal(t, phasePlay, Match(id).Phase)
	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), id, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, "", "", picks, salt2, sealOf(salt3, picks), boxOf("box3"))
	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), id, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, "", "", picks, salt3, "", "")

	want := resolveAll([2]string{a1, b1}, [2]string{picks, braces}, [2]string{picks, braces})
	v := Match(id)
	uassert.Equal(t, phaseEnded, v.Phase)
	uassert.Equal(t, resultName(want.Result), v.Result)
	uassert.Equal(t, "hp", v.Reason)
	urequire.Equal(t, 3, len(v.HP))
	uassert.Equal(t, want.State.Gnomes[0].HP, v.HP[2][0])
	uassert.Equal(t, want.State.Gnomes[1].HP, v.HP[2][1])
	uassert.Equal(t, deckA, v.ChallengerDeck)
	uassert.Equal(t, a1, v.Plans[0][0])
	uassert.Equal(t, b1, v.Plans[0][1])
}

func TestKnockoutEndsTheMatchEarly(cur realm, t *testing.T) {
	reset()
	b1, b2 := "Pick,Anvil Stomp", "Hammer Blow,Cobble Throw"

	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, b1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, picks, salt1, sealOf(salt2, picks), boxOf("box2"))
	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), id, b2)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "unexpected next seal", func() {
		Reveal(cross(cur), id, "", "", picks, salt2, sealOf(salt3, picks), boxOf("box3"))
	})
	Reveal(cross(cur), id, "", "", picks, salt2, "", "")

	v := Match(id)
	uassert.Equal(t, phaseEnded, v.Phase)
	uassert.Equal(t, "b", v.Result)
	uassert.Equal(t, "knockout", v.Reason)
	uassert.Equal(t, 2, len(v.HP))
}

func TestDrawOnHP(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, braces), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, braces, salt1, sealOf(salt2, braces), boxOf("box2"))
	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), id, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, "", "", braces, salt2, sealOf(salt3, braces), boxOf("box3"))
	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), id, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, "", "", braces, salt3, "", "")

	v := Match(id)
	uassert.Equal(t, "draw", v.Result)
	uassert.Equal(t, "hp", v.Reason)
}

func TestSelfPlay(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	Reveal(cross(cur), id, deckA, saltA, picks, salt1, sealOf(salt2, picks), boxOf("box2"))
	Play(cross(cur), id, braces)
	Reveal(cross(cur), id, "", "", picks, salt2, sealOf(salt3, picks), boxOf("box3"))
	Play(cross(cur), id, braces)
	Reveal(cross(cur), id, "", "", picks, salt3, "", "")
	uassert.Equal(t, phaseEnded, Match(id).Phase)
	uassert.Equal(t, id, summaryIDs(Matches(alice, 0, 50)), "a match the player posted and accepted is listed once")
}

func TestAcceptRejects(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	openID := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	namedID := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), bob)

	testing.SetRealm(testing.NewUserRealm(carol))
	cases := []struct {
		name, id, clan, deck, plan, want string
	}{
		{"unknown match", "99", "Ironhide", deckB, braces, "unknown match"},
		{"not the named opponent", namedID, "Ironhide", deckB, braces, "not the named opponent"},
		{"unknown clan", openID, "Elves", deckB, braces, "unknown clan"},
		{"a card twice", openID, "Ironhide", strings.Replace(deckB, "Bulwark", "Stone Guard", 1), braces, "illegal deck"},
		{"a ninth name repeating a card", openID, "Ironhide", deckB + ",Stone Guard", braces, "illegal deck"},
		{"another clan's card", openID, "Ironhide", strings.Replace(deckB, "Bulwark", "Kneecap", 1), braces, "illegal deck"},
		{"unknown card", openID, "Ironhide", strings.Replace(deckB, "Bulwark", "Bulwerk", 1), braces, "unknown card"},
		{"two beats", openID, "Ironhide", deckB, "Pick,Pick", "illegal plan"},
		{"a card outside the deck", openID, "Ironhide", deckB, "Shield Catch,Pick", "illegal plan"},
	}
	for _, c := range cases {
		uassert.AbortsWithMessage(t, cur, c.want, func() {
			Accept(cross(cur), c.id, c.clan, c.deck, c.plan)
		}, c.name)
	}

	Accept(cross(cur), openID, "Ironhide", deckB, braces)
	uassert.AbortsWithMessage(t, cur, "wrong phase", func() {
		Accept(cross(cur), openID, "Ironhide", deckB, braces)
	})

	testing.SkipHeights(7*day + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "challenge expired", func() {
		Accept(cross(cur), namedID, "Ironhide", deckB, braces)
	})
}

// The named opponent is the only one who can accept, and the acceptor then names them, so a
// copy would keep 40 bytes for good.
func TestAcceptForgetsTheNamedOpponent(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	named := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), bob)
	open := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	uassert.Equal(t, bob.String(), Match(named).Opponent)

	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), named, "Ironhide", deckB, braces)
	Accept(cross(cur), open, "Ironhide", deckB, braces)

	uassert.Equal(t, "", recordOf(t, named).opponent.String())
	stored := func(id string) string {
		n, _ := strconv.Atoi(id)
		return chunkRecord(stringAt(&chunks, chunkKey(n)), (n-1)%chunkSize)
	}
	uassert.Equal(t, len(stored(open)), len(stored(named)), "an accepted reserved match stores what an accepted open one does")
	v := Match(named)
	uassert.Equal(t, "", v.Opponent)
	uassert.Equal(t, bob.String(), v.Acceptor)
}

func TestRevealRejects(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	badPlan := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, "Pick,Pick"), boxOf("box1"), "")
	badDeck := Challenge(cross(cur), "Pickers", sealOf(saltA, "Pick"), sealOf(salt1, picks), boxOf("box1"), "")
	longDeck := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA+",Kneecap"), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	Accept(cross(cur), badPlan, "Ironhide", deckB, braces)
	Accept(cross(cur), badDeck, "Ironhide", deckB, braces)
	Accept(cross(cur), longDeck, "Ironhide", deckB, braces)
	next := sealOf(salt2, picks)

	uassert.AbortsWithMessage(t, cur, "not your move", func() {
		Reveal(cross(cur), id, deckA, saltA, picks, salt1, next, boxOf("box2"))
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	cases := []struct {
		name, id, deck, deckSalt, plan, planSalt, nextSeal, nextBox, want string
	}{
		{"no deck", id, "", "", picks, salt1, next, boxOf("box2"), "deck required"},
		{"wrong deck salt", id, deckA, saltB, picks, salt1, next, boxOf("box2"), "seal mismatch"},
		{"wrong plan salt", id, deckA, saltA, picks, salt2, next, boxOf("box2"), "seal mismatch"},
		{"short salt", id, deckA, saltA[2:], picks, salt1, next, boxOf("box2"), "invalid salt"},
		{"illegal plan", badPlan, deckA, saltA, "Pick,Pick", salt1, next, boxOf("box2"), "illegal plan"},
		{"illegal deck", badDeck, "Pick", saltA, picks, salt1, next, boxOf("box2"), "illegal deck"},
		{"a ninth name repeating a card", longDeck, deckA + ",Kneecap", saltA, picks, salt1, next, boxOf("box2"), "illegal deck"},
		{"no next seal", id, deckA, saltA, picks, salt1, "", "", "next seal required"},
		{"bad next seal", id, deckA, saltA, picks, salt1, "abc", boxOf("box2"), "invalid seal"},
		{"no next box", id, deckA, saltA, picks, salt1, next, "", "invalid box"},
		{"next box not base64", id, deckA, saltA, picks, salt1, next, "box", "invalid box"},
	}
	for _, c := range cases {
		uassert.AbortsWithMessage(t, cur, c.want, func() {
			Reveal(cross(cur), c.id, c.deck, c.deckSalt, c.plan, c.planSalt, c.nextSeal, c.nextBox)
		}, c.name)
	}

	Reveal(cross(cur), id, deckA, saltA, picks, salt1, next, boxOf("box2"))
	testing.SetRealm(testing.NewUserRealm(bob))
	Play(cross(cur), id, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "deck already revealed", func() {
		Reveal(cross(cur), id, deckA, saltA, picks, salt2, sealOf(salt3, picks), boxOf("box3"))
	})

	testing.SkipHeights(day + 1)
	uassert.AbortsWithMessage(t, cur, "deadline passed", func() {
		Reveal(cross(cur), id, "", "", picks, salt2, sealOf(salt3, picks), boxOf("box3"))
	})
}

func TestPlayRejects(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	uassert.AbortsWithMessage(t, cur, "wrong phase", func() { Play(cross(cur), id, braces) })

	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, picks, salt1, sealOf(salt2, picks), boxOf("box2"))
	uassert.AbortsWithMessage(t, cur, "not your move", func() { Play(cross(cur), id, braces) })

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "illegal plan", func() { Play(cross(cur), id, "Kneecap,Pick,Pick") })
	testing.SkipHeights(day + 1)
	uassert.AbortsWithMessage(t, cur, "deadline passed", func() { Play(cross(cur), id, braces) })
}

func TestEndClearsSealAndBox(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	resigned := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	forfeited := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), resigned, "Ironhide", deckB, braces)
	Accept(cross(cur), forfeited, "Ironhide", deckB, braces)
	testing.SetRealm(testing.NewUserRealm(alice))
	Resign(cross(cur), resigned)
	Reveal(cross(cur), forfeited, deckA, saltA, picks, salt1, sealOf(salt2, picks), boxOf("box2"))
	testing.SkipHeights(day + 1)
	ClaimForfeit(cross(cur), forfeited)

	for _, id := range []string{resigned, forfeited} {
		uassert.Equal(t, "", Match(id).Box, id)
		m := recordOf(t, id)
		uassert.Equal(t, "", m.deckSeal, id+": a deck seal resigned before its reveal is never checked")
		uassert.Equal(t, "", m.seal, id)
		uassert.Equal(t, "", m.box, id)
	}
}

func showState(s engine.State) string {
	out := "round " + strconv.Itoa(s.Round)
	for _, g := range s.Gnomes {
		out += " | hp " + strconv.Itoa(g.HP) + " vulnerable " + strconv.Itoa(g.Vulnerable) +
			" strength " + strconv.Itoa(g.Strength) + " spent " + strconv.FormatUint(g.Spent, 2)
	}
	return out
}

// After every round of whole matches, the state the realm rebuilds is the engine's own.
func TestStateMatchesEngine(cur realm, t *testing.T) {
	rules := engine.ProofOfConcept()
	salts := []string{salt1, salt2, salt3}
	cases := []struct {
		name   string
		rounds [][2]string
	}{
		{"worked example", [][2]string{{"Chalk Dust,Double Tap", "Hammer Blow,Spiked Shield"}, {picks, braces}, {picks, braces}}},
		{"knockout", [][2]string{{picks, "Pick,Anvil Stomp"}, {picks, "Hammer Blow,Cobble Throw"}}},
		{"draw", [][2]string{{braces, braces}, {braces, braces}, {braces, braces}}},
	}
	for _, c := range cases {
		reset()
		testing.SetRealm(testing.NewUserRealm(alice))
		id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salts[0], c.rounds[0][0]), boxOf("box1"), "")
		testing.SetRealm(testing.NewUserRealm(bob))
		Accept(cross(cur), id, "Ironhide", deckB, c.rounds[0][1])
		uassert.Equal(t, showState(rules.Start()), showState(stateOf(rules, recordOf(t, id))), c.name+" before round 1")

		for r, plans := range c.rounds {
			deck, deckSalt, next, nextBox := "", "", "", ""
			if r == 0 {
				deck, deckSalt = deckA, saltA
			}
			if r+1 < len(c.rounds) {
				next, nextBox = sealOf(salts[r+1], c.rounds[r+1][0]), boxOf("next")
			}
			testing.SetRealm(testing.NewUserRealm(alice))
			Reveal(cross(cur), id, deck, deckSalt, plans[0], salts[r], next, nextBox)

			at := c.name + " after round " + strconv.Itoa(r+1)
			want := resolveAll(c.rounds[:r+1]...).State
			uassert.Equal(t, showState(want), showState(stateOf(rules, recordOf(t, id))), at)
			hp := Match(id).HP
			urequire.Equal(t, r+1, len(hp), at)
			uassert.Equal(t, want.Gnomes[0].HP, hp[r][0], at)
			uassert.Equal(t, want.Gnomes[1].HP, hp[r][1], at)

			if next != "" {
				testing.SetRealm(testing.NewUserRealm(bob))
				Play(cross(cur), id, c.rounds[r+1][1])
			}
		}
	}
}

func TestFirstRevealDropsDeckSeal(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Challenge(cross(cur), "Pickers", sealOf(saltA, deckA), sealOf(salt1, picks), boxOf("box1"), "")
	uassert.Equal(t, sealOf(saltA, deckA), recordOf(t, id).deckSeal)
	testing.SetRealm(testing.NewUserRealm(bob))
	Accept(cross(cur), id, "Ironhide", deckB, braces)
	uassert.Equal(t, sealOf(saltA, deckA), recordOf(t, id).deckSeal)

	testing.SetRealm(testing.NewUserRealm(alice))
	Reveal(cross(cur), id, deckA, saltA, picks, salt1, sealOf(salt2, picks), boxOf("box2"))
	uassert.Equal(t, "", recordOf(t, id).deckSeal)
	uassert.Equal(t, deckA, Match(id).ChallengerDeck)
}
