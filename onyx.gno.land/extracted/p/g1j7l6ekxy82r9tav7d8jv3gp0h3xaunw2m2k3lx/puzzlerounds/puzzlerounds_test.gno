package puzzlerounds

import (
	"encoding/hex"
	"testing"
)

// mustHash decodes a known sha256 hex vector (computed offline, independent
// of HashAnswer) so the test checks the implementation, not itself.
func mustHash(t *testing.T, hexStr string) AnswerHash {
	t.Helper()
	b, err := hex.DecodeString(hexStr)
	if err != nil {
		t.Fatalf("bad test vector: %v", err)
	}
	var h AnswerHash
	copy(h[:], b)
	return h
}

func TestHashAnswer(t *testing.T) {
	// sha256("42") = 73475cb40a568e8da8a045ced110137e159f890ac4da883b6b17dc651b3a8049
	want := mustHash(t, "73475cb40a568e8da8a045ced110137e159f890ac4da883b6b17dc651b3a8049")
	if got := HashAnswer(42); got != want {
		t.Fatalf("HashAnswer(42) = %x, want %x", got, want)
	}
	// sha256("0") = 5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9
	want0 := mustHash(t, "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9")
	if got := HashAnswer(0); got != want0 {
		t.Fatalf("HashAnswer(0) = %x, want %x", got, want0)
	}
}

func TestVerifyAnswer(t *testing.T) {
	h := HashAnswer(2520)
	if !VerifyAnswer(h, 2520) {
		t.Fatalf("VerifyAnswer: correct answer rejected")
	}
	if VerifyAnswer(h, 2521) {
		t.Fatalf("VerifyAnswer: wrong answer accepted")
	}
	if VerifyAnswer(h, 0) {
		t.Fatalf("VerifyAnswer: zero answer accepted")
	}
}

func TestRoundIsOpen(t *testing.T) {
	r := Round{Start: 1000, End: 2000}
	if r.IsOpen(999) {
		t.Fatalf("round open before start")
	}
	if !r.IsOpen(1000) {
		t.Fatalf("round closed at start (inclusive)")
	}
	if !r.IsOpen(1500) {
		t.Fatalf("round closed mid-window")
	}
	if !r.IsOpen(2000) {
		t.Fatalf("round closed at end (inclusive)")
	}
	if r.IsOpen(2001) {
		t.Fatalf("round open after end")
	}
}

func TestDayOf(t *testing.T) {
	if DayOf(0) != 0 {
		t.Fatalf("DayOf(0) = %d, want 0", DayOf(0))
	}
	if DayOf(86399) != 0 {
		t.Fatalf("DayOf(86399) = %d, want 0", DayOf(86399))
	}
	if DayOf(86400) != 1 {
		t.Fatalf("DayOf(86400) = %d, want 1", DayOf(86400))
	}
	// The test VM's fixed time: 1234567890 / 86400 = 14288.
	if DayOf(1234567890) != 14288 {
		t.Fatalf("DayOf(1234567890) = %d, want 14288", DayOf(1234567890))
	}
}

func TestNextStreak(t *testing.T) {
	// First solve ever starts a streak of 1.
	if got := NextStreak(0, 0, 100); got != 1 {
		t.Fatalf("first solve: got %d, want 1", got)
	}
	// Solve the day after the last one extends the streak.
	if got := NextStreak(100, 3, 101); got != 4 {
		t.Fatalf("next-day solve: got %d, want 4", got)
	}
	// A second solve on the same day leaves the streak unchanged.
	if got := NextStreak(100, 3, 100); got != 3 {
		t.Fatalf("same-day solve: got %d, want 3", got)
	}
	// A gap of two or more days restarts the streak.
	if got := NextStreak(100, 5, 102); got != 1 {
		t.Fatalf("gap solve: got %d, want 1", got)
	}
	if got := NextStreak(100, 5, 200); got != 1 {
		t.Fatalf("long-gap solve: got %d, want 1", got)
	}
}

func TestSortLeaders(t *testing.T) {
	a := address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
	b := address("g1skl80cuz8zq3lul9pgz5pc35l2pfzgxgfpsqkx")
	c := address("g1xrcglralkd8zaww0dn3q6qerh2xzq68h86z5r4")
	leaders := []Leader{
		{Solver: a, Solves: 2, Streak: 1},
		{Solver: b, Solves: 5, Streak: 2},
		{Solver: c, Solves: 5, Streak: 4},
	}
	SortLeaders(leaders)
	// c first: 5 solves, higher streak than b. b second. a last.
	if leaders[0].Solver != c || leaders[1].Solver != b || leaders[2].Solver != a {
		t.Fatalf("wrong order: %v %v %v", leaders[0].Solver, leaders[1].Solver, leaders[2].Solver)
	}

	// Tie on solves and streak: lowest address first.
	tied := []Leader{
		{Solver: b, Solves: 1, Streak: 1},
		{Solver: a, Solves: 1, Streak: 1},
	}
	SortLeaders(tied)
	if tied[0].Solver != a || tied[1].Solver != b {
		t.Fatalf("tie-break wrong: %v %v", tied[0].Solver, tied[1].Solver)
	}
}
