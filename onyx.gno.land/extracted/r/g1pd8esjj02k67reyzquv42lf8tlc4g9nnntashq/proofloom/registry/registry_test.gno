package registry

import (
	"testing"
)

const (
	adminAddr = address("g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq")
	aliceAddr = address("g1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	bobAddr   = address("g1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
)

// expectAbort asserts that f aborts (panics) when executed. It relies on the
// gno `revive` builtin, which captures the panic value without unwinding the
// test frame — the sanctioned way to assert reverts on crossing calls.
func expectAbort(t *testing.T, f func()) {
	t.Helper()
	if r := revive(f); r == nil {
		t.Fatal("expected abort, got none")
	}
}

// NOTE: testing.SetRealm(...) is frame-local: it MUST be called inline within
// the test function body for the realm to apply to subsequent cross(cur)
// calls made from that frame.

func TestRegisterProjectFlow(cur realm, t *testing.T) {
	if !IsInitialized() {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	GrantRegistrar(cross(cur), aliceAddr)

	before := ProjectCount()
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	RegisterProject(cross(cur), "core-api", "Core API", "Primary service", "github.com/example/core-api", "service", "public")

	if ProjectCount() != before+1 {
		t.Fatalf("expected project count to grow by 1, got %d -> %d", before, ProjectCount())
	}
	p, ok := GetPublicProject("core-api")
	if !ok {
		t.Fatal("project should be public readable")
	}
	if p.Owner != aliceAddr {
		t.Fatalf("owner mismatch: %s", p.Owner)
	}
	if p.CreatedAt <= 0 {
		t.Fatal("timestamp missing")
	}

	// duplicate registration must abort
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	expectAbort(t, func() {
		RegisterProject(cross(cur), "core-api", "Dup", "", "", "", "public")
	})

	// invalid id must abort
	expectAbort(t, func() {
		RegisterProject(cross(cur), "INVALID ID", "Bad", "", "", "", "public")
	})
}

func TestUnauthorizedRegistration(cur realm, t *testing.T) {
	if !IsInitialized() {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
	}

	// bob is not a registrar: must abort
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	expectAbort(t, func() {
		RegisterProject(cross(cur), "bob-proj-x", "Bob", "", "", "", "public")
	})
}

func TestOwnershipTransfer(cur realm, t *testing.T) {
	if !IsInitialized() {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	GrantRegistrar(cross(cur), aliceAddr)

	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	RegisterProject(cross(cur), "transfer-me", "Transfer", "", "", "", "public")

	// bob cannot transfer alice's project
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	expectAbort(t, func() {
		TransferProject(cross(cur), "transfer-me", bobAddr)
	})

	// owner transfers to bob
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	TransferProject(cross(cur), "transfer-me", bobAddr)
	if !IsProjectOwner("transfer-me", bobAddr) {
		t.Fatal("bob should now own project")
	}
	if IsProjectOwner("transfer-me", aliceAddr) {
		t.Fatal("alice should no longer own project")
	}

	// transfer to self must abort
	expectAbort(t, func() {
		TransferProject(cross(cur), "transfer-me", bobAddr)
	})

	// transfer to invalid address must abort
	expectAbort(t, func() {
		TransferProject(cross(cur), "transfer-me", address("not-an-address"))
	})
}

func TestComponentsAndVisibility(cur realm, t *testing.T) {
	if !IsInitialized() {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	GrantRegistrar(cross(cur), aliceAddr)

	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	RegisterProject(cross(cur), "priv-proj", "Private", "", "", "", "private")
	RegisterComponent(cross(cur), "priv-proj-lib", "priv-proj", "lib", "MIT", "library")

	// foreign reader cannot see private project
	if _, ok := GetProjectFor("priv-proj", bobAddr); ok {
		t.Fatal("private project must be hidden from foreign readers")
	}
	if _, ok := GetPublicProject("priv-proj"); ok {
		t.Fatal("private project must not be public")
	}
	if _, ok := GetProjectFor("priv-proj", aliceAddr); !ok {
		t.Fatal("owner must see own private project")
	}

	// bob cannot register component on alice's project
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	expectAbort(t, func() {
		RegisterComponent(cross(cur), "bob-lib-x", "priv-proj", "x", "", "library")
	})

	// invalid artifact type must abort
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	expectAbort(t, func() {
		RegisterComponent(cross(cur), "bad-type-x", "priv-proj", "x", "", "quantum")
	})

	// duplicate component must abort
	expectAbort(t, func() {
		RegisterComponent(cross(cur), "priv-proj-lib", "priv-proj", "dup", "", "library")
	})

	// deprecate
	DeprecateComponent(cross(cur), "priv-proj-lib")
	c, ok := GetComponent("priv-proj-lib")
	if !ok || !c.Deprecated {
		t.Fatal("component should be deprecated")
	}

	// bob cannot deprecate
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	expectAbort(t, func() {
		DeprecateComponent(cross(cur), "priv-proj-lib")
	})
}

func TestArchiveAndRestore(cur realm, t *testing.T) {
	if !IsInitialized() {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
	}

	testing.SetRealm(testing.NewUserRealm(adminAddr))
	GrantRegistrar(cross(cur), aliceAddr)

	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	RegisterProject(cross(cur), "archive-me", "Archive", "", "", "", "public")

	ArchiveProject(cross(cur), "archive-me")
	if _, ok := GetPublicProject("archive-me"); ok {
		t.Fatal("archived public project must not be public")
	}
	if !HasProject("archive-me") {
		t.Fatal("archived project still exists")
	}
	RestoreProject(cross(cur), "archive-me")
	if _, ok := GetPublicProject("archive-me"); !ok {
		t.Fatal("restored project must be public again")
	}

	// bob cannot archive
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	expectAbort(t, func() {
		ArchiveProject(cross(cur), "archive-me")
	})

	// bob cannot restore
	expectAbort(t, func() {
		RestoreProject(cross(cur), "archive-me")
	})
}

func TestAdminCannotBeUsurped(cur realm, t *testing.T) {
	if !IsInitialized() {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
	}

	if !IsProtocolAdmin(adminAddr) {
		t.Fatal("admin should be the deployer")
	}

	// alice cannot elevate herself
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	expectAbort(t, func() {
		SetAdmin(cross(cur), aliceAddr)
	})
	expectAbort(t, func() {
		GrantRegistrar(cross(cur), aliceAddr)
	})

	// admin CAN transfer admin, then original loses power
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	SetAdmin(cross(cur), bobAddr)
	if IsProtocolAdmin(adminAddr) {
		t.Fatal("old admin must lose power")
	}
	if !IsProtocolAdmin(bobAddr) {
		t.Fatal("bob must be admin")
	}

	// hand admin back to the deployer for the rest of the suite
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	SetAdmin(cross(cur), adminAddr)
	if !IsProtocolAdmin(adminAddr) {
		t.Fatal("admin handback failed")
	}
}

func TestListingDeterministic(cur realm, t *testing.T) {
	if !IsInitialized() {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
	}

	ids := ListPublicProjectIDs()
	for i := 1; i < len(ids); i++ {
		if ids[i-1] > ids[i] {
			t.Fatalf("public ids not sorted: %v", ids)
		}
	}
	all := ListProjectIDs()
	if len(all) == 0 {
		t.Fatal("expected registered projects")
	}
	if !HasProject(all[0]) {
		t.Fatal("head of newest-first listing must exist")
	}

	if NormalizeRepo("https://github.com/x/y/") != "github.com/x/y" {
		t.Fatalf("NormalizeRepo broken: %s", NormalizeRepo("https://github.com/x/y/"))
	}
}
