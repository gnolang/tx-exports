package rulecalc

import "testing"

func validRule() Rule {
	return Rule{
		Method:   WeightedSum,
		Criteria: []Criterion{{Name: "security", Weight: 3}},
		Quorum:   2,
		Tie:      LowestID,
	}
}

func TestValidateOK(t *testing.T) {
	if err := validRule().Validate(3); err != nil {
		t.Fatalf("valid rule rejected: %v", err)
	}
	r := validRule()
	r.Method = MajorityFirst
	r.Tie = Refund
	r.Criteria = []Criterion{{"a", 1}, {"b", 10}, {"c", 5}, {"d", 2}}
	r.Quorum = 3
	if err := r.Validate(3); err != nil {
		t.Fatalf("valid rule (4 criteria, quorum == evaluators) rejected: %v", err)
	}
}

func TestValidateRejects(t *testing.T) {
	cases := []struct {
		name string
		mod  func(r *Rule)
	}{
		{"no criteria", func(r *Rule) { r.Criteria = nil }},
		{"five criteria", func(r *Rule) {
			r.Criteria = []Criterion{{"a", 1}, {"b", 1}, {"c", 1}, {"d", 1}, {"e", 1}}
		}},
		{"weight 0", func(r *Rule) { r.Criteria = []Criterion{{"a", 0}} }},
		{"weight 11", func(r *Rule) { r.Criteria = []Criterion{{"a", 11}} }},
		{"empty name", func(r *Rule) { r.Criteria = []Criterion{{"", 1}} }},
		{"duplicate name", func(r *Rule) { r.Criteria = []Criterion{{"a", 1}, {"a", 2}} }},
		{"quorum 0", func(r *Rule) { r.Quorum = 0 }},
		{"quorum above evaluators", func(r *Rule) { r.Quorum = 4 }},
		{"unknown method", func(r *Rule) { r.Method = Method(0) }},
		{"unknown method high", func(r *Rule) { r.Method = Method(3) }},
		{"unknown tie", func(r *Rule) { r.Tie = TieBreak(0) }},
		{"unknown tie high", func(r *Rule) { r.Tie = TieBreak(3) }},
	}
	for _, c := range cases {
		r := validRule()
		c.mod(&r)
		if err := r.Validate(3); err == nil {
			t.Errorf("%s: expected error, got nil", c.name)
		}
	}
}
