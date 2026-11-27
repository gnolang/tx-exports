package doorwarden

import (
	"strings"
	"testing"
)

func TestScoreAllPass(cur realm, t *testing.T) {
	if got := ScoreResults("PPPPPPPP"); got != 100 {
		t.Fatalf("expected 100, got %d", got)
	}
}

func TestScoreMixed(cur realm, t *testing.T) {
	// Weights are 3,3,2,2,2,1,1,1 (total 15). Six passes earn 13,
	// so 13/15 rounds to 87.
	if got := ScoreResults("PPPPPPFF"); got != 87 {
		t.Fatalf("expected 87, got %d", got)
	}
	if got := ScoreResults("FFFFFFFF"); got != 0 {
		t.Fatalf("expected 0, got %d", got)
	}
}

func TestScoreNA(cur realm, t *testing.T) {
	if got := ScoreResults("NNNNNNNN"); got != 0 {
		t.Fatalf("expected 0 for all-N/A, got %d", got)
	}
	if got := ScoreResults("PNNNNNNN"); got != 100 {
		t.Fatalf("expected 100 for single applicable pass, got %d", got)
	}
}

func TestVerdict(cur realm, t *testing.T) {
	cases := []struct {
		score int
		want  string
	}{
		{100, "Tavern-ready"},
		{90, "Tavern-ready"},
		{70, "Mostly sound"},
		{40, "Needs work"},
		{39, "Turned away"},
		{0, "Turned away"},
	}
	for _, c := range cases {
		if got := Verdict(c.score); got != c.want {
			t.Fatalf("Verdict(%d): expected %q, got %q", c.score, c.want, got)
		}
	}
}

func TestSubmitReviewFlow(cur realm, t *testing.T) {
	path := "gno.land/r/example/vault"
	out := SubmitReview(cross(cur), path, "PPPPPPPP", "solid work")
	if !strings.Contains(out, "100/100") {
		t.Fatalf("unexpected summary: %s", out)
	}
	if got := BestScore(path); got != 100 {
		t.Fatalf("expected best score 100, got %d", got)
	}
	if got := ReviewCount(path); got != 1 {
		t.Fatalf("expected 1 review, got %d", got)
	}

	// Same reviewer resubmits: verdict updates, count does not grow.
	SubmitReview(cross(cur), path, "FFFFFFFF", "found a hole")
	if got := BestScore(path); got != 0 {
		t.Fatalf("expected best score 0 after update, got %d", got)
	}
	if got := ReviewCount(path); got != 1 {
		t.Fatalf("expected review count to stay 1, got %d", got)
	}
	if got := BestScore("gno.land/r/example/never-reviewed"); got != -1 {
		t.Fatalf("expected -1 for unreviewed path, got %d", got)
	}
}

func TestInvalidResultsPanics(cur realm, t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatalf("expected panic for short results string")
		}
	}()
	ScoreResults("PP")
}

func TestValidPkgPath(cur realm, t *testing.T) {
	// SubmitReview panics on invalid paths; a panic inside a crossing
	// call cannot be recovered by the caller, so the validation helper
	// is tested directly.
	if validPkgPath("not-a-pkgpath") {
		t.Fatalf("expected invalid path to be rejected")
	}
	if validPkgPath("gno.land/r/bad path/with spaces") {
		t.Fatalf("expected path with spaces to be rejected")
	}
	if !validPkgPath("gno.land/r/example/vault") {
		t.Fatalf("expected realm path to be accepted")
	}
	if !validPkgPath("gno.land/p/example/lib") {
		t.Fatalf("expected package path to be accepted")
	}
}

func TestSanitize(cur realm, t *testing.T) {
	if got := sanitize("a*b`c[d]"); got != "a b c d " {
		t.Fatalf("unexpected sanitize output: %q", got)
	}
}

func TestRender(cur realm, t *testing.T) {
	home := Render("")
	if !strings.Contains(home, "Doorwarden") || !strings.Contains(home, "caller-auth") {
		t.Fatalf("home render missing expected content")
	}
	if !strings.Contains(Render("checks"), "Payment verification") {
		t.Fatalf("checks render missing expected content")
	}
	SubmitReview(cross(cur), "gno.land/r/example/vault", "PPPPPPPP", "")
	if !strings.Contains(Render("leaderboard"), "gno.land/r/example/vault") {
		t.Fatalf("leaderboard missing reviewed realm")
	}
	if !strings.Contains(Render("reviews"), "100/100") {
		t.Fatalf("reviews render missing expected content")
	}
}
