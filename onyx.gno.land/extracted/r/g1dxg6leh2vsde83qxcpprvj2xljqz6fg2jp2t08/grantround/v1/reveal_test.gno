package grantround

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// adoptedRound: e1, e2 (and optional extra listed evaluators) joined with their sponsors,
// rule "weighted a:3,b:1 quorum q lowest" adopted. Height is in the rule phase.
func adoptedRound(cur realm, quorum int, tie string) int {
	return adoptedRoundSalted(cur, tSalt, quorum, tie)
}

func adoptedRoundSalted(cur realm, salt string, quorum int, tie string) int {
	id, _ := newRoundSalted(cur, salt, e1, s1, e2, s2, e3, s3)
	joinAll(cur, id, e1, s1, e2, s2, e3, s3)
	testing.SkipHeights(11)
	testing.SetRealm(user(e1))
	seq := ProposeRule(cross(cur), id, "weighted", "a:3,b:1", quorum, tie, "")
	testing.SetRealm(user(e2))
	ApproveRule(cross(cur), id, seq)
	testing.SetRealm(user(e3))
	ApproveRule(cross(cur), id, seq)
	return id
}

func revealedRound(cur realm, quorum int, tie string) int {
	id := adoptedRound(cur, quorum, tie)
	testing.SetRealm(user(customer))
	Reveal(cross(cur), id, testAppsEncoded(), tSalt)
	return id
}

func TestReveal(cur realm, t *testing.T) {
	id := adoptedRound(cur, 2, "lowest")
	testing.SetRealm(user(outsider))
	uassert.AbortsContains(t, cur, "customer", func() { Reveal(cross(cur), id, testAppsEncoded(), tSalt) })
	testing.SetRealm(user(customer))
	uassert.AbortsContains(t, cur, "hash", func() { Reveal(cross(cur), id, testAppsEncoded(), tWrong) }, "wrong salt")
	uassert.AbortsContains(t, cur, "hash", func() {
		Reveal(cross(cur), id, "Alpha|gno.land/r/x/alpha|"+p1.String()+"\nBeta|gno.land/r/x/beta|"+p1.String(), tSalt)
	}, "swapped payout")
	r := mustGet(id)
	uassert.True(t, r.Apps == nil, "state unchanged after rejected reveals")

	Reveal(cross(cur), id, testAppsEncoded(), tSalt)
	uassert.Equal(t, 2, len(r.Apps))
	uassert.Equal(t, p1, r.Apps[1].Payout)
	uassert.AbortsContains(t, cur, "reveal phase", func() { Reveal(cross(cur), id, testAppsEncoded(), tSalt) }, "second reveal")
}

func TestRevealOutsidePhase(cur realm, t *testing.T) {
	id := ruleRound(cur) // no rule adopted
	testing.SetRealm(user(customer))
	uassert.AbortsContains(t, cur, "reveal phase", func() { Reveal(cross(cur), id, testAppsEncoded(), tSalt) }, "before adoption")

	id = adoptedRound(cur, 2, "lowest")
	testing.SkipHeights(20) // past HReveal (h0+30)
	testing.SetRealm(user(customer))
	uassert.AbortsContains(t, cur, "reveal phase", func() { Reveal(cross(cur), id, testAppsEncoded(), tSalt) }, "after deadline")
}

// The short salt opens the commitment, so only the length can reject it.
func TestRevealShortSalt(cur realm, t *testing.T) {
	for _, salt := range []string{"", tSalt[:31]} {
		id := adoptedRoundSalted(cur, salt, 2, "lowest")
		testing.SetRealm(user(customer))
		uassert.AbortsContains(t, cur, "salt too short", func() { Reveal(cross(cur), id, testAppsEncoded(), salt) })
		uassert.True(t, mustGet(id).Apps == nil, "nothing revealed")
	}
	id := adoptedRoundSalted(cur, tSalt, 2, "lowest")
	testing.SetRealm(user(customer))
	Reveal(cross(cur), id, testAppsEncoded(), tSalt)
	uassert.Equal(t, 32, len(tSalt))
	uassert.Equal(t, 2, len(mustGet(id).Apps), "32 characters are enough")
}
