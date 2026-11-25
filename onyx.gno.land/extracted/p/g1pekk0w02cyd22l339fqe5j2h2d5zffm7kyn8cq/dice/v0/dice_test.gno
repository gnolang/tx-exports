package dice

import (
	"strconv"
	"testing"
)

func TestRollFromSeedRange(t *testing.T) {
	// 1000 different seeds: every roll must be in [1, 6] and every face
	// must show up (a rough uniformity sanity check).
	seen := map[int]bool{}
	for i := 0; i < 1000; i++ {
		seed := []byte("tavern-dice-seed-" + strconv.Itoa(i))
		roll := RollFromSeed(seed)
		if roll < 1 || roll > 6 {
			t.Fatalf("roll %d out of range for seed %d", roll, i)
		}
		seen[roll] = true
	}
	if len(seen) != 6 {
		t.Fatalf("expected all 6 faces in 1000 rolls, got %d", len(seen))
	}
	// Deterministic: same seed, same roll.
	a := RollFromSeed([]byte("same-seed"))
	b := RollFromSeed([]byte("same-seed"))
	if a != b {
		t.Fatalf("same seed gave different rolls: %d vs %d", a, b)
	}
}

func TestNumberPayout(t *testing.T) {
	if got := NumberPayout(1000); got != 5000 {
		t.Fatalf("NumberPayout(1000) = %d, want 5000", got)
	}
	if got := NumberPayout(0); got != 0 {
		t.Fatalf("NumberPayout(0) = %d, want 0", got)
	}
	if got := NumberPayout(200000); got != 1000000 {
		t.Fatalf("NumberPayout(200000) = %d, want 1000000", got)
	}
}

func TestParityPayout(t *testing.T) {
	if got := ParityPayout(1000); got != 1900 {
		t.Fatalf("ParityPayout(1000) = %d, want 1900", got)
	}
	if got := ParityPayout(1005); got != 1909 {
		// 1005*19/10 = 1909 (integer division truncates).
		t.Fatalf("ParityPayout(1005) = %d, want 1909", got)
	}
	if got := ParityPayout(0); got != 0 {
		t.Fatalf("ParityPayout(0) = %d, want 0", got)
	}
}

func TestMaxBets(t *testing.T) {
	// Bankroll 1,000,000ugnot: number max 50,000 (payout 250,000 = 1/4),
	// parity max 125,000 (payout 237,500 < 1/4).
	if got := MaxNumberBet(1000000); got != 50000 {
		t.Fatalf("MaxNumberBet(1000000) = %d, want 50000", got)
	}
	if got := MaxParityBet(1000000); got != 125000 {
		t.Fatalf("MaxParityBet(1000000) = %d, want 125000", got)
	}
	// Empty bankroll: no bets allowed.
	if got := MaxNumberBet(0); got != 0 {
		t.Fatalf("MaxNumberBet(0) = %d, want 0", got)
	}
	if got := MaxParityBet(-5); got != 0 {
		t.Fatalf("MaxParityBet(-5) = %d, want 0", got)
	}
	// Solvency: worst-case payouts never exceed a quarter of the bankroll.
	bankroll := int64(1000000)
	if NumberPayout(MaxNumberBet(bankroll)) > bankroll/4 {
		t.Fatalf("number max payout exceeds bankroll/4")
	}
	if ParityPayout(MaxParityBet(bankroll)) > bankroll/4 {
		t.Fatalf("parity max payout exceeds bankroll/4")
	}
}
