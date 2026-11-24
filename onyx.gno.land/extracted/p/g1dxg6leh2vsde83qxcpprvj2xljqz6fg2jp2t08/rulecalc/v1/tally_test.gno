package rulecalc

import "testing"

// two criteria, weights 3 and 1
func ws(tie TieBreak, quorum int) Rule {
	return Rule{Method: WeightedSum, Criteria: []Criterion{{"a", 3}, {"b", 1}}, Quorum: quorum, Tie: tie}
}

func sheet(ev string, scores ...[]int) Sheet {
	return Sheet{Evaluator: address(ev), Scores: scores}
}

func TestComputeWeightedSum(t *testing.T) {
	// app0: 3*5+1*5=20 and 3*4+1*0=12 -> 32 ; app1: 3*6+1*0=18 and 3*6+1*2=20 -> 38
	sheets := []Sheet{
		sheet("e1", []int{5, 5}, []int{6, 0}),
		sheet("e2", []int{4, 0}, []int{6, 2}),
	}
	w, paid := Compute(ws(LowestID, 2), 2, sheets)
	if !paid || w != 1 {
		t.Fatalf("want winner 1 paid, got %d %v", w, paid)
	}
	tot := Totals(ws(LowestID, 2), 2, sheets)
	if len(tot) != 2 || tot[0] != 32 || tot[1] != 38 {
		t.Fatalf("totals: want [32 38], got %v", tot)
	}
}

func TestComputeMajorityFirst(t *testing.T) {
	r := ws(LowestID, 3)
	r.Method = MajorityFirst
	// sheet firsts: e1 -> 0, e2 -> 1, e3 -> 1. Weighted sums would favor 0 heavily.
	sheets := []Sheet{
		sheet("e1", []int{10, 10}, []int{0, 0}),
		sheet("e2", []int{5, 0}, []int{6, 0}),
		sheet("e3", []int{5, 0}, []int{6, 0}),
	}
	w, paid := Compute(r, 2, sheets)
	if !paid || w != 1 {
		t.Fatalf("want winner 1 paid, got %d %v", w, paid)
	}
	tot := Totals(r, 2, sheets)
	if tot[0] != 1 || tot[1] != 2 {
		t.Fatalf("first-place counts: want [1 2], got %v", tot)
	}
}

func TestComputeMajorityFirstInSheetTieLowestID(t *testing.T) {
	r := ws(LowestID, 1)
	r.Method = MajorityFirst
	// in-sheet tie between app0 and app1 -> first place is app0
	w, paid := Compute(r, 2, []Sheet{sheet("e1", []int{2, 2}, []int{2, 2})})
	if !paid || w != 0 {
		t.Fatalf("want winner 0 paid, got %d %v", w, paid)
	}
}

func TestComputeTieLowestID(t *testing.T) {
	sheets := []Sheet{sheet("e1", []int{2, 0}, []int{1, 3})} // 6 vs 6
	w, paid := Compute(ws(LowestID, 1), 2, sheets)
	if !paid || w != 0 {
		t.Fatalf("want winner 0 paid, got %d %v", w, paid)
	}
}

func TestComputeTieRefund(t *testing.T) {
	sheets := []Sheet{sheet("e1", []int{2, 0}, []int{1, 3})} // 6 vs 6
	_, paid := Compute(ws(Refund, 1), 2, sheets)
	if paid {
		t.Fatal("tie with Refund must not pay")
	}
}

func TestComputeQuorum(t *testing.T) {
	sheets := []Sheet{
		sheet("e1", []int{5, 5}, []int{6, 0}),
		sheet("e2", []int{4, 0}, []int{6, 2}),
	}
	_, paid := Compute(ws(LowestID, 3), 2, sheets)
	if paid {
		t.Fatal("below quorum must not pay")
	}
}

func TestComputeNoSheets(t *testing.T) {
	_, paid := Compute(ws(LowestID, 1), 2, nil)
	if paid {
		t.Fatal("no sheets must not pay")
	}
}

func TestComputeNoApps(t *testing.T) {
	_, paid := Compute(ws(LowestID, 1), 0, []Sheet{sheet("e1")})
	if paid {
		t.Fatal("no apps must not pay")
	}
}

func TestValidateSheet(t *testing.T) {
	r := ws(LowestID, 1)
	if err := ValidateSheet(r, 2, sheet("e1", []int{0, 10}, []int{10, 0})); err != nil {
		t.Fatalf("valid sheet rejected: %v", err)
	}
	bad := []Sheet{
		sheet("e1", []int{11, 0}, []int{0, 0}),           // score 11
		sheet("e1", []int{-1, 0}, []int{0, 0}),           // score -1
		sheet("e1", []int{1, 1}),                         // too few apps
		sheet("e1", []int{1, 1}, []int{1, 1}, []int{1, 1}), // too many apps
		sheet("e1", []int{1}, []int{1, 1}),               // too few criteria
		sheet("e1", []int{1, 1, 1}, []int{1, 1}),         // too many criteria
	}
	for i, s := range bad {
		if err := ValidateSheet(r, 2, s); err == nil {
			t.Errorf("bad sheet %d accepted", i)
		}
	}
}
