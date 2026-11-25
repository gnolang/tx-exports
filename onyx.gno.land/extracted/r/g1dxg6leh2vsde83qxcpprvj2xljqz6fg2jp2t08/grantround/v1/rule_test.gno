package grantround

import (
	"testing"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
	"gno.land/p/nt/uassert/v0"
)

// ruleRound: e1, e2, e3 listed; e1, e2 joined; height moved into the rule phase.
func ruleRound(cur realm) int {
	id, _ := newRound(cur, e1, s1, e2, s2, e3, s3)
	joinAll(cur, id, e1, s1, e2, s2)
	testing.SkipHeights(11)
	return id
}

func TestProposeRuleRejects(cur realm, t *testing.T) {
	id, _ := newRound(cur, e1, s1, e2, s2)
	joinAll(cur, id, e1, s1, e2, s2)
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "rule phase", func() {
		ProposeRule(cross(cur), id, "weighted", "security:3", 1, "lowest", "")
	}, "during join")

	id = ruleRound(cur)
	testing.SetRealm(user(e3))
	uassert.AbortsContains(t, cur, "joined evaluator", func() {
		ProposeRule(cross(cur), id, "weighted", "security:3", 1, "lowest", "")
	}, "listed but not joined")
	testing.SetRealm(user(outsider))
	uassert.AbortsContains(t, cur, "joined evaluator", func() {
		ProposeRule(cross(cur), id, "weighted", "security:3", 1, "lowest", "")
	}, "outsider")
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "quorum", func() {
		ProposeRule(cross(cur), id, "weighted", "security:3", 3, "lowest", "")
	}, "quorum above joined")
	uassert.AbortsContains(t, cur, "method", func() {
		ProposeRule(cross(cur), id, "vibes", "security:3", 1, "lowest", "")
	})
	uassert.AbortsContains(t, cur, "tie", func() {
		ProposeRule(cross(cur), id, "weighted", "security:3", 1, "coin", "")
	})
	uassert.AbortsContains(t, cur, "criteri", func() {
		ProposeRule(cross(cur), id, "weighted", "security", 1, "lowest", "")
	})
}

func TestRuleAdoptedUnanimously(cur realm, t *testing.T) {
	id := ruleRound(cur)
	testing.SetRealm(user(e1))
	seq := ProposeRule(cross(cur), id, "majority", "security:3, idioms:2", 2, "refund", "safety first")
	r := mustGet(id)
	uassert.Equal(t, 1, seq)
	uassert.True(t, r.Rule == nil, "not adopted after proposer vote alone")
	uassert.True(t, r.Votes[0], "proposer voted")

	testing.SetRealm(user(e2))
	ApproveRule(cross(cur), id, seq)
	uassert.True(t, r.Rule != nil, "adopted")
	uassert.True(t, r.Rule.Method == rulecalc.MajorityFirst, "method")
	uassert.True(t, r.Rule.Tie == rulecalc.Refund, "tie")
	uassert.Equal(t, 2, len(r.Rule.Criteria))
	uassert.Equal(t, "idioms", r.Rule.Criteria[1].Name)
	uassert.Equal(t, 2, r.Rule.Criteria[1].Weight)
	uassert.Equal(t, "safety first", r.Rule.Rationale)

	uassert.AbortsContains(t, cur, "already adopted", func() { ApproveRule(cross(cur), id, seq) })
	uassert.AbortsContains(t, cur, "already adopted", func() {
		ProposeRule(cross(cur), id, "weighted", "x:1", 1, "lowest", "")
	})
}

func TestNewProposalResetsVotes(cur realm, t *testing.T) {
	id := ruleRound(cur)
	testing.SetRealm(user(e1))
	first := ProposeRule(cross(cur), id, "weighted", "a:1", 1, "lowest", "")
	testing.SetRealm(user(e2))
	second := ProposeRule(cross(cur), id, "weighted", "b:2", 2, "lowest", "")
	r := mustGet(id)
	uassert.Equal(t, 2, second)
	uassert.False(t, r.Votes[0], "e1 vote reset")
	uassert.True(t, r.Votes[1], "e2 voted for own proposal")

	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "stale", func() { ApproveRule(cross(cur), id, first) })
	ApproveRule(cross(cur), id, second)
	uassert.Equal(t, "b", r.Rule.Criteria[0].Name)
}

func TestSingleEvaluatorAdoptsOnPropose(cur realm, t *testing.T) {
	id, _ := newRound(cur, e1, s1, e2, s2)
	joinAll(cur, id, e1, s1)
	testing.SkipHeights(11)
	testing.SetRealm(user(e1))
	ProposeRule(cross(cur), id, "weighted", "a:1", 1, "lowest", "")
	uassert.True(t, mustGet(id).Rule != nil, "adopted")
}

func TestRulePhaseCloses(cur realm, t *testing.T) {
	id := ruleRound(cur)
	testing.SetRealm(user(e1))
	seq := ProposeRule(cross(cur), id, "weighted", "a:1", 1, "lowest", "")
	testing.SkipHeights(10)
	testing.SetRealm(user(e2))
	uassert.AbortsContains(t, cur, "rule phase", func() { ApproveRule(cross(cur), id, seq) })
}
