package releases

import (
	"testing"

	core "gno.land/r/g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq/proofloom/core"
	reg "gno.land/r/g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq/proofloom/registry"
)

const (
	adminAddr = address("g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq")
	aliceAddr = address("g1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	bobAddr   = address("g1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
)

const digestA = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2"

func expectAbort(t *testing.T, f func()) {
	t.Helper()
	if r := revive(f); r == nil {
		t.Fatal("expected abort, got none")
	}
}

// seedRegistry initializes the registry realm (shared across test binaries)
// and registers a project owned by alice.
func seedProject(cur realm, projectID string) {
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	if !reg.IsInitialized() {
		reg.Init(cross(cur))
	}
	reg.GrantRegistrar(cross(cur), aliceAddr)
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	if !reg.HasProject(projectID) {
		reg.RegisterProject(cross(cur), projectID, "Proj", "desc", "github.com/example/proj", "service", "public")
	}
}

func TestReleaseStateMachine(cur realm, t *testing.T) {
	seedProject(cur, "sm-proj")
	if !initialized() {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
	}

	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	id := CreateRelease(cross(cur), "sm-proj", "1.0.0", "abc1234", "main", "github.com/example/proj", "")

	if id != "sm-proj-1.0.0" {
		t.Fatalf("unexpected release id %s", id)
	}

	// pre-publication states are hidden from foreign readers
	if _, ok := GetRelease(id, bobAddr); ok {
		t.Fatal("draft release must be hidden from foreign readers")
	}
	if _, ok := GetRelease(id, aliceAddr); !ok {
		t.Fatal("publisher must see own draft release")
	}

	// publish without evidence must abort
	expectAbort(t, func() {
		testing.SetRealm(testing.NewUserRealm(aliceAddr))
		Publish(cross(cur), id)
	})

	SetEvidence(cross(cur), id, digestA)
	r, _ := GetRelease(id, aliceAddr)
	if r.Status != core.ReleaseEvidencePending {
		t.Fatalf("expected EVIDENCE_PENDING, got %s", r.Status)
	}

	// invalid digest aborts
	expectAbort(t, func() {
		testing.SetRealm(testing.NewUserRealm(aliceAddr))
		SetEvidence(cross(cur), id, "nothex")
	})

	// full happy path
	MarkValidating(cross(cur), id)
	RequireReview(cross(cur), id)
	Approve(cross(cur), id)
	Publish(cross(cur), id)

	r, _ = GetRelease(id, bobAddr)
	if r.Status != core.ReleasePublished {
		t.Fatalf("expected PUBLISHED, got %s", r.Status)
	}
	if r.PublishedAt <= 0 {
		t.Fatal("publication timestamp missing")
	}

	// published records are public
	if _, ok := GetRelease(id, bobAddr); !ok {
		t.Fatal("published release must be public")
	}
	if ReleaseStatus(id) != core.ReleasePublished {
		t.Fatal("status query broken")
	}

	MarkVerified(cross(cur), id)
	if ReleaseStatus(id) != core.ReleaseVerified {
		t.Fatal("expected VERIFIED")
	}

	// digest lookup must find it
	found := FindByDigest(digestA)
	if len(found) != 1 || found[0] != id {
		t.Fatalf("digest lookup failed: %v", found)
	}
}

func TestReleaseAuthorization(cur realm, t *testing.T) {
	seedProject(cur, "authz-proj")
	if !initialized() {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
	}

	// bob cannot create releases on alice's project
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	expectAbort(t, func() {
		CreateRelease(cross(cur), "authz-proj", "0.1.0", "abc1234", "main", "", "")
	})

	// alice creates; bob cannot touch it
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	id := CreateRelease(cross(cur), "authz-proj", "0.2.0", "abc1234", "main", "", "")
	SetEvidence(cross(cur), id, digestA)

	testing.SetRealm(testing.NewUserRealm(bobAddr))
	expectAbort(t, func() {
		Approve(cross(cur), id)
	})
	expectAbort(t, func() {
		Revoke(cross(cur), id)
	})

	// admin CAN act (protocol admin override)
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	MarkValidating(cross(cur), id)
	Approve(cross(cur), id)
	Publish(cross(cur), id)

	// invalid transition: approve after publish
	expectAbort(t, func() {
		testing.SetRealm(testing.NewUserRealm(aliceAddr))
		Approve(cross(cur), id)
	})
}

func TestRevokeAndSupersede(cur realm, t *testing.T) {
	seedProject(cur, "rv-proj")
	if !initialized() {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
	}

	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	id1 := CreateRelease(cross(cur), "rv-proj", "2.0.0", "abc1234", "main", "", "")
	SetEvidence(cross(cur), id1, digestA)
	MarkValidating(cross(cur), id1)
	Approve(cross(cur), id1)
	Publish(cross(cur), id1)

	id2 := CreateRelease(cross(cur), "rv-proj", "2.1.0", "abc1234", "main", "", "")
	SetEvidence(cross(cur), id2, digestA)
	MarkValidating(cross(cur), id2)
	Approve(cross(cur), id2)
	Publish(cross(cur), id2)

	// supersede 2.0.0 with 2.1.0
	Supersede(cross(cur), id1, id2)
	r1, _ := GetRelease(id1, bobAddr)
	if r1.Status != core.ReleaseSuperseded || r1.SupersededBy != id2 {
		t.Fatalf("supersede failed: %s -> %s", r1.Status, r1.SupersededBy)
	}

	// cross-project supersede must abort
	idX := CreateRelease(cross(cur), "sm-proj", "9.9.9", "abc1234", "main", "", "")
	SetEvidence(cross(cur), idX, digestA)
	MarkValidating(cross(cur), idX)
	Approve(cross(cur), idX)
	Publish(cross(cur), idX)
	expectAbort(t, func() {
		Supersede(cross(cur), id2, idX)
	})

	// revoke remains publicly visible
	Revoke(cross(cur), id2)
	r2, ok := GetRelease(id2, bobAddr)
	if !ok || r2.Status != core.ReleaseRevoked {
		t.Fatalf("revoked release must remain visible: %v %s", ok, r2.Status)
	}
}
