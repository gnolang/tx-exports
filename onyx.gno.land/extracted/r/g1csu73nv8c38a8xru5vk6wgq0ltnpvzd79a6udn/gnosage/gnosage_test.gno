package gnosage

import (
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
)

// Test addresses, reused from the gnolang/gno examples (valid bech32).
var (
	alice = address("g125em6arxsnj49vx35f0n0z34putv5ty3376fg5")
	bob   = address("g1skl80cuz8zq3lul9pgz5pc35l2pfzgxgfpsqkx")
	carol = address("g1wymu47drhr0kuq2098m792lytgtj2nyx77yrsm")
)

// resetState rebuilds realm state and makes alice the owner. Tests call
// it first because package state persists across tests in one run.
func resetState() {
	Ownable = ownable.NewWithAddress(alice)
	reviews = avl.NewTree()
	versions = avl.NewTree()
	latestAgent = avl.NewTree()
	reviewers = avl.NewTree()
	reviewCount = 0
}

func TestPostReviewAgent(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	RegisterReviewer(cross(cur), bob)
	if !IsReviewer(bob) {
		t.Fatal("bob should be a registered reviewer")
	}

	testing.SetRealm(testing.NewUserRealm(bob))
	version, err := PostReview(cross(cur), "gno.land/r/demo/counter", 80, 70, 60, 90, 85, "Solid little realm.", "lint:pass;tests:present")
	if err != nil {
		t.Fatalf("PostReview failed: %v", err)
	}
	if version != 1 {
		t.Fatalf("version = %d, want 1", version)
	}
	r := GetReview("gno.land/r/demo/counter", 1)
	if r == nil {
		t.Fatal("GetReview returned nil")
	}
	if !r.Agent {
		t.Fatal("review by a registered reviewer should be marked agent")
	}
	if r.Score != 80 || r.Docs != 70 || r.Tests != 60 || r.Safety != 90 || r.Quality != 85 {
		t.Fatalf("scores mismatch: %+v", r)
	}
	if r.Reviewer != bob {
		t.Fatalf("reviewer = %s, want %s", r.Reviewer, bob)
	}
	latest := LatestAgentReview("gno.land/r/demo/counter")
	if latest == nil || latest.Version != 1 {
		t.Fatal("LatestAgentReview should return version 1")
	}
	if ReviewCount() != 1 {
		t.Fatalf("ReviewCount = %d, want 1", ReviewCount())
	}
}

func TestPostReviewHuman(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(carol))
	version, err := PostReview(cross(cur), "gno.land/r/demo/counter", 50, 50, 50, 50, 50, "Meh.", "lint:pass")
	if err != nil {
		t.Fatalf("PostReview failed: %v", err)
	}
	if version != 1 {
		t.Fatalf("version = %d, want 1", version)
	}
	r := GetReview("gno.land/r/demo/counter", 1)
	if r.Agent {
		t.Fatal("review by an unregistered caller should not be marked agent")
	}
	if LatestAgentReview("gno.land/r/demo/counter") != nil {
		t.Fatal("human reviews must not become the headline agent verdict")
	}
	if VersionCount("gno.land/r/demo/counter") != 1 {
		t.Fatal("VersionCount should count human reviews too")
	}
}

func TestPostReviewVersions(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	RegisterReviewer(cross(cur), bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	if _, err := PostReview(cross(cur), "gno.land/r/demo/counter", 70, 70, 70, 70, 70, "v1.", ""); err != nil {
		t.Fatalf("first PostReview failed: %v", err)
	}
	v2, err := PostReview(cross(cur), "gno.land/r/demo/counter", 85, 85, 85, 85, 85, "v2, improved.", "")
	if err != nil {
		t.Fatalf("second PostReview failed: %v", err)
	}
	if v2 != 2 {
		t.Fatalf("version = %d, want 2", v2)
	}
	if VersionCount("gno.land/r/demo/counter") != 2 {
		t.Fatal("VersionCount should be 2")
	}
	latest := LatestAgentReview("gno.land/r/demo/counter")
	if latest == nil || latest.Score != 85 {
		t.Fatal("latest agent review should be the v2 one")
	}
	// History is kept: v1 is still readable.
	old := GetReview("gno.land/r/demo/counter", 1)
	if old == nil || old.Score != 70 {
		t.Fatal("v1 review should still be stored")
	}
}

func TestPostReviewValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(bob))
	cases := []struct {
		name    string
		path    string
		score   int
		verdict string
		checks  string
	}{
		{"empty path", "", 50, "ok", ""},
		{"bad prefix", "evil.com/r/x", 50, "ok", ""},
		{"score too high", "gno.land/r/a/b", 101, "ok", ""},
		{"score negative", "gno.land/r/a/b", -1, "ok", ""},
		{"empty verdict", "gno.land/r/a/b", 50, "   ", ""},
		{"verdict too long", "gno.land/r/a/b", 50, strings.Repeat("x", 1001), ""},
		{"checks too long", "gno.land/r/a/b", 50, "ok", strings.Repeat("x", 2001)},
	}
	for _, c := range cases {
		if _, err := PostReview(cross(cur), c.path, c.score, 50, 50, 50, 50, c.verdict, c.checks); err == nil {
			t.Fatalf("%s: expected an error, got none", c.name)
		}
	}
	if ReviewCount() != 0 {
		t.Fatalf("invalid reviews must not be stored, count = %d", ReviewCount())
	}
}

func TestUnregisterReviewer(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	RegisterReviewer(cross(cur), bob)
	UnregisterReviewer(cross(cur), bob)
	if IsReviewer(bob) {
		t.Fatal("bob should no longer be a reviewer")
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	if _, err := PostReview(cross(cur), "gno.land/r/demo/counter", 50, 50, 50, 50, 50, "ok", ""); err != nil {
		t.Fatalf("PostReview failed: %v", err)
	}
	if GetReview("gno.land/r/demo/counter", 1).Agent {
		t.Fatal("review after unregister should not be marked agent")
	}
}

func TestRenderIndexAndDetail(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice))
	RegisterReviewer(cross(cur), bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	if _, err := PostReview(cross(cur), "gno.land/r/demo/counter", 80, 70, 60, 90, 85, "Solid.", "lint:pass"); err != nil {
		t.Fatalf("PostReview failed: %v", err)
	}
	index := Render("")
	if !strings.Contains(index, "gno.land/r/demo/counter") {
		t.Fatal("index should list the reviewed realm")
	}
	if !strings.Contains(index, "80") {
		t.Fatal("index should show the score")
	}
	detail := Render("gno.land/r/demo/counter")
	if !strings.Contains(detail, "Solid.") {
		t.Fatal("detail should show the verdict")
	}
	if !strings.Contains(detail, "v1") {
		t.Fatal("detail should show the version")
	}
	// A verdict with markdown-breaking characters must be flattened.
	testing.SetRealm(testing.NewUserRealm(bob))
	if _, err := PostReview(cross(cur), "gno.land/r/demo/counter", 10, 10, 10, 10, 10, "bad\n[link](http://x) | table", ""); err != nil {
		t.Fatalf("PostReview failed: %v", err)
	}
	detail = Render("gno.land/r/demo/counter")
	if strings.Contains(detail, "[link](http://x)") {
		t.Fatal("rendered verdict must not carry a live link")
	}
}

func TestReviewedPaths(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(bob))
	if _, err := PostReview(cross(cur), "gno.land/r/b/two", 50, 50, 50, 50, 50, "ok", ""); err != nil {
		t.Fatalf("PostReview failed: %v", err)
	}
	if _, err := PostReview(cross(cur), "gno.land/r/a/one", 50, 50, 50, 50, 50, "ok", ""); err != nil {
		t.Fatalf("PostReview failed: %v", err)
	}
	paths := ReviewedPaths()
	if len(paths) != 2 {
		t.Fatalf("ReviewedPaths = %v, want 2 paths", paths)
	}
	if paths[0] != "gno.land/r/a/one" || paths[1] != "gno.land/r/b/two" {
		t.Fatalf("ReviewedPaths = %v, want lexicographic order", paths)
	}
}
