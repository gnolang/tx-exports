package grantround

import (
	"chain/runtime"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
)

// joinedIndex returns the index of a joined evaluator, or panics.
func (r *Round) joinedIndex(a address) int {
	i := r.evaluatorIndex(a)
	if i < 0 || r.Sponsors[i] == "" {
		panic("grantround: caller is not a joined evaluator")
	}
	return i
}

func (r *Round) maybeAdopt() {
	for i, s := range r.Sponsors {
		if s != "" && !r.Votes[i] {
			return
		}
	}
	r.Rule = r.Proposal
}

// ProposeRule replaces the current proposal, clears all votes and records the
// proposer's own vote. Returns the proposal sequence number that ApproveRule
// must name. Criteria: "name:weight,..."; method: weighted|majority; tie: lowest|refund.
func ProposeRule(cur realm, roundID int, method, criteria string, quorum int, tie, rationale string) int {
	r := mustGet(roundID)
	if r.Rule != nil {
		panic("grantround: rule already adopted")
	}
	if PhaseOf(r, runtime.ChainHeight()) != PhaseRule {
		panic("grantround: not in the rule phase")
	}
	i := r.joinedIndex(cur.Previous().Address())
	rule, err := parseRule(method, criteria, quorum, tie, rationale)
	if err != nil {
		panic("grantround: " + err.Error())
	}
	if err := rule.Validate(r.joined()); err != nil {
		panic("grantround: " + err.Error())
	}
	r.Proposal = &rule
	r.ProposalSeq++
	for k := range r.Votes {
		r.Votes[k] = false
	}
	r.Votes[i] = true
	r.maybeAdopt()
	return r.ProposalSeq
}

// ApproveRule records the caller's vote for proposal seq. The rule is adopted
// once every joined evaluator has voted for the same proposal.
func ApproveRule(cur realm, roundID int, seq int) {
	r := mustGet(roundID)
	if r.Rule != nil {
		panic("grantround: rule already adopted")
	}
	if PhaseOf(r, runtime.ChainHeight()) != PhaseRule {
		panic("grantround: not in the rule phase")
	}
	i := r.joinedIndex(cur.Previous().Address())
	if r.Proposal == nil || seq != r.ProposalSeq {
		panic("grantround: stale or unknown proposal")
	}
	r.Votes[i] = true
	r.maybeAdopt()
}

// Reveal publishes the applications committed to at creation. Only the
// customer may call it, after the rule is adopted and before HReveal.
// apps is one "Title|PkgPath|Payout" line per application, joined by "\n";
// salt has at least minSaltLen bytes.
func Reveal(cur realm, roundID int, apps string, salt string) {
	r := mustGet(roundID)
	if cur.Previous().Address() != r.Customer {
		panic("grantround: only the round customer can reveal")
	}
	if PhaseOf(r, runtime.ChainHeight()) != PhaseReveal {
		panic("grantround: not in the reveal phase")
	}
	mustLongSalt(salt)
	list, err := parseApps(apps)
	if err != nil {
		panic("grantround: " + err.Error())
	}
	if rulecalc.AppsDigest(list, salt) != r.AppsHash {
		panic("grantround: applications do not match the committed hash")
	}
	r.Apps = list
}
