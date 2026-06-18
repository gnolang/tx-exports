package memba_dao

import (
	"strings"
	"testing"
)

// TestInit verifies the DAO is correctly initialized with expected roles and members.
// The init() function runs automatically before tests.
func TestInit(t *testing.T) {
	// ── Members ─────────────────────────────────────────────
	membersCount := daoPrivate.Members.MembersCount()
	if membersCount != 1 {
		t.Fatalf("Expected 1 member (founding multisig), got %d", membersCount)
	}

	// Verify founding member is the samcrew-core-test1 multisig
	founderAddr := "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"
	if !daoPrivate.Members.IsMember(founderAddr) {
		t.Fatalf("Founding member %s is not registered", founderAddr)
	}

	// ── Roles ────────────────────────────────────────────────
	roles := daoPrivate.Members.GetRoles()
	expectedRoles := []string{"admin", "dev", "ops", "member"}
	if len(roles) != len(expectedRoles) {
		t.Fatalf("Expected %d roles, got %d: %v", len(expectedRoles), len(roles), roles)
	}

	for _, expected := range expectedRoles {
		found := false
		for _, role := range roles {
			if role == expected {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("Missing expected role '%s'. Got roles: %v", expected, roles)
		}
	}

	// ── Founder Roles ────────────────────────────────────────
	if !daoPrivate.Members.HasRole(founderAddr, "admin") {
		t.Fatal("Founder should have 'admin' role")
	}
	if !daoPrivate.Members.HasRole(founderAddr, "dev") {
		t.Fatal("Founder should have 'dev' role")
	}
}

// TestRender verifies the Render function produces non-empty output.
func TestRender(t *testing.T) {
	// Root render (home page)
	output := Render("")
	if len(output) == 0 {
		t.Fatal("Render('') returned empty output")
	}

	// Should contain DAO name
	if !strings.Contains(output, "MembaDAO") {
		t.Fatal("Render('') should contain 'MembaDAO'")
	}
}

// TestRenderMembers verifies the members page renders correctly.
func TestRenderMembers(t *testing.T) {
	output := Render("members")
	if len(output) == 0 {
		t.Fatal("Render('members') returned empty output")
	}
}

// TestRenderProposals verifies the proposals page renders correctly.
func TestRenderProposals(t *testing.T) {
	output := Render("proposals")
	if len(output) == 0 {
		t.Fatal("Render('proposals') returned empty output")
	}
}
