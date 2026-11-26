package bounty

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
)

func alice() address { return testutils.TestAddress("alice") }

func bob() address { return testutils.TestAddress("bob") }

func carol() address { return testutils.TestAddress("carol") }

// resetState clears the shared realm state. gno test runs all tests in
// one machine, so globals persist across tests in a file.
func resetState() {
	bounties = nil
}

// NOTE: testing.SetRealm and the crossing calls (PostBounty/ClaimBounty/
// CompleteBounty with cross(cur)) must be made directly in the test
// function body. Routing them through a helper breaks caller identity:
// SetRealm only overrides the calling frame (lost when the helper
// returns), and cross(cur) from inside a helper makes cur.Previous()
// return the wrong address.

func TestPostBountySingle(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice()))
	id, err := PostBounty(cross(cur), "Fix the README", "fix the docs", "100ugnot")
	if err != nil {
		t.Fatalf("PostBounty failed: %v", err)
	}
	if id != 0 {
		t.Fatalf("expected first bounty id 0, got %d", id)
	}
	if BountyCount() != 1 {
		t.Fatalf("expected 1 bounty, got %d", BountyCount())
	}
	got, err := GetBounty(0)
	if err != nil {
		t.Fatalf("GetBounty failed: %v", err)
	}
	for _, want := range []string{"Fix the README", "100ugnot", "open", alice().String()} {
		if !strings.Contains(got, want) {
			t.Fatalf("GetBounty missing %q: %s", want, got)
		}
	}
}

func TestPostBountyEmptyTitle(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice()))
	_, err := PostBounty(cross(cur), "", "desc", "100ugnot")
	if err == nil {
		t.Fatalf("expected error for empty title, got nil")
	}
	if BountyCount() != 0 {
		t.Fatalf("expected 0 bounties, got %d", BountyCount())
	}
}

func TestClaimBountyValid(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice()))
	if _, err := PostBounty(cross(cur), "Fix the README", "fix the docs", "100ugnot"); err != nil {
		t.Fatalf("PostBounty failed: %v", err)
	}
	testing.SetRealm(testing.NewUserRealm(bob()))
	if err := ClaimBounty(cross(cur), 0); err != nil {
		t.Fatalf("ClaimBounty failed: %v", err)
	}
	got, _ := GetBounty(0)
	for _, want := range []string{"claimed", bob().String()} {
		if !strings.Contains(got, want) {
			t.Fatalf("GetBounty missing %q after claim: %s", want, got)
		}
	}
	rendered := Render("")
	if !strings.Contains(rendered, "Fix the README") || !strings.Contains(rendered, "claimed") {
		t.Fatalf("Render missing bounty/claimed status: %s", rendered)
	}
}

func TestClaimBountyTwice(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice()))
	if _, err := PostBounty(cross(cur), "Fix the README", "fix the docs", "100ugnot"); err != nil {
		t.Fatalf("PostBounty failed: %v", err)
	}
	testing.SetRealm(testing.NewUserRealm(bob()))
	if err := ClaimBounty(cross(cur), 0); err != nil {
		t.Fatalf("first claim failed: %v", err)
	}
	testing.SetRealm(testing.NewUserRealm(carol()))
	if err := ClaimBounty(cross(cur), 0); err == nil {
		t.Fatalf("expected error for second claim, got nil")
	}
	got, _ := GetBounty(0)
	if !strings.Contains(got, bob().String()) {
		t.Fatalf("claimer changed after rejected second claim: %s", got)
	}
}

func TestClaimOwnBounty(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice()))
	if _, err := PostBounty(cross(cur), "Fix the README", "fix the docs", "100ugnot"); err != nil {
		t.Fatalf("PostBounty failed: %v", err)
	}
	// Alice is already the caller; claiming her own bounty must fail.
	if err := ClaimBounty(cross(cur), 0); err == nil {
		t.Fatalf("expected error for self-claim, got nil")
	}
	got, _ := GetBounty(0)
	if !strings.Contains(got, "open") {
		t.Fatalf("bounty should still be open after rejected self-claim: %s", got)
	}
}

func TestCompleteByNonCreator(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice()))
	if _, err := PostBounty(cross(cur), "Fix the README", "fix the docs", "100ugnot"); err != nil {
		t.Fatalf("PostBounty failed: %v", err)
	}
	testing.SetRealm(testing.NewUserRealm(bob()))
	if err := ClaimBounty(cross(cur), 0); err != nil {
		t.Fatalf("claim failed: %v", err)
	}
	// The claimer cannot complete it.
	if err := CompleteBounty(cross(cur), 0); err == nil {
		t.Fatalf("expected error when claimer completes, got nil")
	}
	// A third party cannot complete it either.
	testing.SetRealm(testing.NewUserRealm(carol()))
	if err := CompleteBounty(cross(cur), 0); err == nil {
		t.Fatalf("expected error when third party completes, got nil")
	}
	got, _ := GetBounty(0)
	if !strings.Contains(got, "claimed") {
		t.Fatalf("bounty should still be claimed after rejected completes: %s", got)
	}
}

func TestCompleteByCreator(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice()))
	if _, err := PostBounty(cross(cur), "Fix the README", "fix the docs", "100ugnot"); err != nil {
		t.Fatalf("PostBounty failed: %v", err)
	}
	testing.SetRealm(testing.NewUserRealm(bob()))
	if err := ClaimBounty(cross(cur), 0); err != nil {
		t.Fatalf("claim failed: %v", err)
	}
	testing.SetRealm(testing.NewUserRealm(alice()))
	if err := CompleteBounty(cross(cur), 0); err != nil {
		t.Fatalf("creator complete failed: %v", err)
	}
	got, _ := GetBounty(0)
	if !strings.Contains(got, "done") {
		t.Fatalf("expected status done after creator completes: %s", got)
	}
}

func TestCompleteOpenBounty(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice()))
	if _, err := PostBounty(cross(cur), "Fix the README", "fix the docs", "100ugnot"); err != nil {
		t.Fatalf("PostBounty failed: %v", err)
	}
	if err := CompleteBounty(cross(cur), 0); err == nil {
		t.Fatalf("expected error completing an unclaimed bounty, got nil")
	}
}

func TestInvalidID(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(alice()))
	if _, err := PostBounty(cross(cur), "Fix the README", "fix the docs", "100ugnot"); err != nil {
		t.Fatalf("PostBounty failed: %v", err)
	}
	testing.SetRealm(testing.NewUserRealm(bob()))
	if err := ClaimBounty(cross(cur), 99); err == nil {
		t.Fatalf("expected error claiming unknown id, got nil")
	}
	if err := CompleteBounty(cross(cur), -1); err == nil {
		t.Fatalf("expected error completing unknown id, got nil")
	}
	if _, err := GetBounty(5); err == nil {
		t.Fatalf("expected error getting unknown id, got nil")
	}
}
