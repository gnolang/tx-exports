package engine

import "testing"

func TestResolveMatchesModel(t *testing.T) {
	rs := ProofOfConcept()
	for i, tc := range resolveCases {
		a, okA := rs.PlanOf(tc.A...)
		b, okB := rs.PlanOf(tc.B...)
		if !okA || !okB {
			t.Fatalf("case %d: unknown card in %v or %v", i, tc.A, tc.B)
		}
		s := State{Round: tc.Round}
		for side := 0; side < 2; side++ {
			s.Gnomes[side] = Gnome{HP: tc.Start[side][0], Vulnerable: tc.Start[side][1], Strength: tc.Start[side][2]}
		}
		o := rs.Resolve(s, a, b)
		if o.Result != tc.Result {
			t.Errorf("case %d (%v vs %v): result %d, want %d", i, tc.A, tc.B, o.Result, tc.Result)
			continue
		}
		if tc.End == ([2][3]int{}) {
			continue
		}
		for side := 0; side < 2; side++ {
			g := o.State.Gnomes[side]
			got := [3]int{g.HP, g.Vulnerable, g.Strength}
			if got != tc.End[side] {
				t.Errorf("case %d (%v vs %v): side %d ends %v, want %v", i, tc.A, tc.B, side, got, tc.End[side])
			}
		}
	}
}
