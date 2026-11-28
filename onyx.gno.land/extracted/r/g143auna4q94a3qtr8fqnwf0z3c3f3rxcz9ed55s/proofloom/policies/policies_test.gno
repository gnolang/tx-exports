package policies

import (
	"testing"

	reg "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/registry"
)

const (
	adminAddr = address("g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq")
	aliceAddr = address("g1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	bobAddr   = address("g1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
)

func expectAbort(t *testing.T, f func()) {
	t.Helper()
	if r := revive(f); r == nil {
		t.Fatal("expected abort, got none")
	}
}

func seed(cur realm) {
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	if !reg.IsInitialized() {
		reg.Init(cross(cur))
	}
	reg.GrantRegistrar(cross(cur), aliceAddr)
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	if !reg.HasProject("pol-proj") {
		reg.RegisterProject(cross(cur), "pol-proj", "Pol", "d", "repo", "service", "public")
	}
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	if !Initialized() {
		Init(cross(cur))
	}
}

func TestPolicyVersioning(cur realm, t *testing.T) {
	seed(cur)

	// bob cannot set policy on alice's project
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	expectAbort(t, func() {
		SetPolicy(cross(cur), "pol-proj", []string{"BUILD_PROVENANCE"}, 1, nil, false, false)
	})

	// alice sets v1
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	v1 := SetPolicy(cross(cur), "pol-proj", []string{"BUILD_PROVENANCE", "TEST_EXECUTION"}, 1, nil, true, false)
	if v1 != 1 {
		t.Fatalf("expected version 1, got %d", v1)
	}

	// alice sets v2 with an allow-list
	v2 := SetPolicy(cross(cur), "pol-proj", []string{"BUILD_PROVENANCE"}, 2, []string{"g1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, false, true)
	if v2 != 2 {
		t.Fatalf("expected version 2, got %d", v2)
	}

	p, ok := GetPolicy("pol-proj")
	if !ok || p.Version != 2 || p.MinApprovals != 2 {
		t.Fatalf("active policy wrong: %+v", p)
	}
	if len(p.RequireCategories) != 1 {
		t.Fatal("v2 categories wrong")
	}

	// archived v1 still readable
	p1, ok := GetPolicyVersion("pol-proj", 1)
	if !ok || p1.MinApprovals != 1 || len(p1.RequireCategories) != 2 {
		t.Fatalf("archived v1 wrong: %+v", p1)
	}

	// invalid category aborts
	expectAbort(t, func() {
		testing.SetRealm(testing.NewUserRealm(aliceAddr))
		SetPolicy(cross(cur), "pol-proj", []string{"NOPE"}, 0, nil, false, false)
	})

	// invalid issuer aborts
	expectAbort(t, func() {
		SetPolicy(cross(cur), "pol-proj", nil, 0, []string{"bogus"}, false, false)
	})

	// clear archives v2 and resets to defaults
	ClearPolicy(cross(cur), "pol-proj")
	if _, ok := GetPolicy("pol-proj"); ok {
		t.Fatal("policy should be cleared")
	}
	if PolicyVersionCount("pol-proj") != 2 {
		t.Fatalf("expected 2 archived versions, got %d", PolicyVersionCount("pol-proj"))
	}
}
