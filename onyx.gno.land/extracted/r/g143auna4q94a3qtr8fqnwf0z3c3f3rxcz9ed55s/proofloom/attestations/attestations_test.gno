package attestations

import (
	"testing"

	core "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/core"
	reg "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/registry"
	rel "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/releases"
)

const (
	adminAddr = address("g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq")
	aliceAddr = address("g1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	bobAddr   = address("g1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
)

const digestA = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2"
const digestB = "b1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2"

func expectAbort(t *testing.T, f func()) {
	t.Helper()
	if r := revive(f); r == nil {
		t.Fatal("expected abort, got none")
	}
}

// seed initializes all dependency realms and returns a published release id.
func seed(cur realm) string {
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	if !reg.IsInitialized() {
		reg.Init(cross(cur))
	}
	reg.GrantRegistrar(cross(cur), aliceAddr)
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	if !reg.HasProject("att-proj") {
		reg.RegisterProject(cross(cur), "att-proj", "Att", "d", "repo", "service", "public")
	}
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	if !rel.Initialized() {
		rel.Init(cross(cur))
	}
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	if !rel.HasRelease("att-proj-1.0.0") {
		id := rel.CreateRelease(cross(cur), "att-proj", "1.0.0", "abc1234", "main", "", "")
		rel.SetEvidence(cross(cur), id, digestA)
		rel.MarkValidating(cross(cur), id)
		rel.Approve(cross(cur), id)
		rel.Publish(cross(cur), id)
	}
	if !initDone {
		testing.SetRealm(testing.NewUserRealm(adminAddr))
		Init(cross(cur))
		initDone = true
	}
	return "att-proj-1.0.0"
}

var initDone bool

func TestIssueAndDuplicatePrevention(cur realm, t *testing.T) {
	rid := seed(cur)

	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	id := Issue(cross(cur), core.SubjectRelease, rid, core.AttestBuild, digestB, 0)
	if id == "" {
		t.Fatal("attestation id missing")
	}
	if EffectiveStatus(id) != core.AttestationActive {
		t.Fatal("expected active")
	}

	// duplicate active attestation from same issuer for same subject+category
	expectAbort(t, func() {
		testing.SetRealm(testing.NewUserRealm(aliceAddr))
		Issue(cross(cur), core.SubjectRelease, rid, core.AttestBuild, digestB, 0)
	})

	// a different issuer may attest the same subject+category
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	id2 := Issue(cross(cur), core.SubjectRelease, rid, core.AttestBuild, digestB, 0)
	if EffectiveStatus(id2) != core.AttestationActive {
		t.Fatal("second issuer attestation should be active")
	}

	if AttestationCount() < 2 {
		t.Fatal("expected at least 2 attestations")
	}
}

func TestRevocation(cur realm, t *testing.T) {
	rid := seed(cur)

	testing.SetRealm(testing.NewUserRealm(bobAddr))
	id := Issue(cross(cur), core.SubjectRelease, rid, core.AttestTest, digestB, 0)

	// bob (issuer) revokes
	Revoke(cross(cur), id, "superseded by retest")
	if EffectiveStatus(id) != core.AttestationRevoked {
		t.Fatal("expected revoked")
	}
	a, _ := GetAttestation(id)
	if a.RevocationReason != "superseded by retest" || a.RevokedAt <= 0 {
		t.Fatal("revocation metadata missing")
	}

	// after revocation, the issuer may re-issue a fresh attestation
	id2 := Issue(cross(cur), core.SubjectRelease, rid, core.AttestTest, digestB, 0)
	if EffectiveStatus(id2) != core.AttestationActive {
		t.Fatal("re-issue after revocation should work")
	}

	// alice cannot revoke bob's attestation
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	expectAbort(t, func() {
		Revoke(cross(cur), id2, "not my attestation")
	})

	// admin CAN revoke
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	Revoke(cross(cur), id2, "admin hold")
	if EffectiveStatus(id2) != core.AttestationRevoked {
		t.Fatal("admin revocation failed")
	}

	// revoked attestations remain publicly readable
	a2, ok := GetAttestation(id2)
	if !ok || a2.Status != core.AttestationRevoked {
		t.Fatal("revoked record must remain visible")
	}
}

func TestValidationGuards(cur realm, t *testing.T) {
	rid := seed(cur)

	// invalid category
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	expectAbort(t, func() {
		Issue(cross(cur), core.SubjectRelease, rid, "MAGIC", digestB, 0)
	})

	// invalid digest
	expectAbort(t, func() {
		Issue(cross(cur), core.SubjectRelease, rid, core.AttestBuild, "tooshort", 0)
	})

	// phantom subject
	expectAbort(t, func() {
		Issue(cross(cur), core.SubjectRelease, "ghost-release-9.9.9", core.AttestBuild, digestB, 0)
	})

	// expiry in the past
	expectAbort(t, func() {
		Issue(cross(cur), core.SubjectRelease, rid, core.AttestBenchmark, digestB, 1000)
	})

	// project subject works
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	pid := Issue(cross(cur), core.SubjectProject, "att-proj", core.AttestOwnership, digestB, 0)
	if EffectiveStatus(pid) != core.AttestationActive {
		t.Fatal("project attestation should be active")
	}
}
