// Package rulecalc holds the evaluation rule schema for a grant round and the
// deterministic computation of its outcome. It has no state and moves no coins.
package rulecalc

import (
	"errors"
	"strconv"
)

// Method is how evaluator score sheets are aggregated into a winner.
type Method int

const (
	// WeightedSum: the winner has the highest sum of weight*score over all sheets.
	WeightedSum Method = iota + 1
	// MajorityFirst: each sheet's first place is its highest weighted app;
	// the winner has the most first places.
	MajorityFirst
)

// TieBreak decides a top-level tie.
type TieBreak int

const (
	// LowestID: the tied app with the lowest ID wins.
	LowestID TieBreak = iota + 1
	// Refund: no winner; the grant returns to the customer.
	Refund
)

const (
	MinCriteria = 1
	MaxCriteria = 4
	MinWeight   = 1
	MaxWeight   = 10
	MinScore    = 0
	MaxScore    = 10
)

// Criterion is one named, weighted evaluation axis.
type Criterion struct {
	Name   string
	Weight int
}

// Rule is the procedure the evaluators agree on before applications are revealed.
// Rationale is shown to readers and never affects computation.
type Rule struct {
	Method    Method
	Criteria  []Criterion
	Quorum    int
	Tie       TieBreak
	Rationale string
}

// Validate checks the rule against the schema for a round with nEvaluators joined evaluators.
func (r Rule) Validate(nEvaluators int) error {
	if r.Method != WeightedSum && r.Method != MajorityFirst {
		return errors.New("rulecalc: unknown method " + strconv.Itoa(int(r.Method)))
	}
	if r.Tie != LowestID && r.Tie != Refund {
		return errors.New("rulecalc: unknown tie-break " + strconv.Itoa(int(r.Tie)))
	}
	n := len(r.Criteria)
	if n < MinCriteria || n > MaxCriteria {
		return errors.New("rulecalc: need 1-4 criteria, got " + strconv.Itoa(n))
	}
	seen := map[string]bool{}
	for _, c := range r.Criteria {
		if c.Name == "" {
			return errors.New("rulecalc: criterion name is empty")
		}
		if seen[c.Name] {
			return errors.New("rulecalc: duplicate criterion " + c.Name)
		}
		seen[c.Name] = true
		if c.Weight < MinWeight || c.Weight > MaxWeight {
			return errors.New("rulecalc: weight of " + c.Name + " must be 1-10")
		}
	}
	if r.Quorum < 1 || r.Quorum > nEvaluators {
		return errors.New("rulecalc: quorum must be between 1 and " + strconv.Itoa(nEvaluators))
	}
	return nil
}
