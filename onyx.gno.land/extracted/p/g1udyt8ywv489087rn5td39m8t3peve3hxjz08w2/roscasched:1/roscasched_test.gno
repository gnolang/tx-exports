package roscasched

import (

	"testing"
)

func TestOrderIsDeterministic(t *testing.T) {
	seed := Seed(7, 123456, []string{"g1alice", "g1bob", "g1carol", "g1dave", "g1erin"})
	a := Order(5, seed)
	b := Order(5, seed)

	if len(a) != 5 || len(b) != 5 {
		t.Fatalf("expected 5 entries, got %d and %d", len(a), len(b))
	}
	for i := 0; i < 5; i++ {
		if a[i] != b[i] {
			t.Fatalf("order is not deterministic at %d: %d vs %d", i, a[i], b[i])
		}
	}
}

func TestOrderIsAPermutation(t *testing.T) {
	seed := Seed(1, 99, []string{"g1a", "g1b", "g1c", "g1d", "g1e", "g1f", "g1g", "g1h"})
	order := Order(8, seed)

	seen := make([]bool, 8)
	for _, idx := range order {
		if idx < 0 || idx >= 8 {
			t.Fatalf("index out of range: %d", idx)
		}
		if seen[idx] {
			t.Fatalf("duplicate index %d in %v", idx, order)
		}
		seen[idx] = true
	}
	for i, ok := range seen {
		if !ok {
			t.Fatalf("index %d missing from %v", i, order)
		}
	}
}

func TestOrderDependsOnSeed(t *testing.T) {
	// Two seeds that differ only by activation height must not collapse to the
	// same order for a sizeable roster: that is the property the whole
	// "nobody can pick the winner" claim rests on.
	members := []string{"g1a", "g1b", "g1c", "g1d", "g1e", "g1f", "g1g", "g1h", "g1i", "g1j"}
	s1 := Seed(3, 1000, members)
	s2 := Seed(3, 1001, members)
	o1 := Order(10, s1)
	o2 := Order(10, s2)

	same := true
	for i := 0; i < 10; i++ {
		if o1[i] != o2[i] {
			same = false
		}
	}
	if same {
		t.Fatalf("different seeds produced the same order")
	}
}

func TestSeedIgnoresMemberOrder(t *testing.T) {
	a := Seed(1, 5, []string{"g1b", "g1a", "g1c"})
	b := Seed(1, 5, []string{"g1c", "g1a", "g1b"})
	if a != b {
		t.Fatalf("seed should not depend on input order: %q vs %q", a, b)
	}
}
