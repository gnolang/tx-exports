package verify

import (
	"testing"

	core "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/core"
	reg "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/registry"
	rel "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/releases"
	att "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/attestations"
	pol "gno.land/r/g143auna4q94a3qtr8fqnwf0z3c3f3rxcz9ed55s/proofloom/policies"
)

const (
	adminAddr = address("g1pd8esjj02k67reyzquv42lf8tlc4g9nnntashq")
	aliceAddr = address("g1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	bobAddr   = address("g1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
)

const (
	digestA = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2"
	digestB = "b1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2"
	digestC = "c1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2"
)

func seedProjectID(cur realm, projectID string) {
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	if !reg.IsInitialized() {
		reg.Init(cross(cur))
	}
	if !rel.Initialized() {
		rel.Init(cross(cur))
	}
	if !att.Initialized() {
		att.Init(cross(cur))
	}
	if !pol.Initialized() {
		pol.Init(cross(cur))
	}
	reg.GrantRegistrar(cross(cur), aliceAddr)
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	if !reg.HasProject(projectID) {
		reg.RegisterProject(cross(cur), projectID, "Proj", "d", "repo", "service", "public")
	}
}

func seed(cur realm) {
	testing.SetRealm(testing.NewUserRealm(adminAddr))
	if !reg.IsInitialized() {
		reg.Init(cross(cur))
	}
	if !rel.Initialized() {
		rel.Init(cross(cur))
	}
	if !att.Initialized() {
		att.Init(cross(cur))
	}
	if !pol.Initialized() {
		pol.Init(cross(cur))
	}
	reg.GrantRegistrar(cross(cur), aliceAddr)
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	if !reg.HasProject("vf-proj") {
		reg.RegisterProject(cross(cur), "vf-proj", "Verify Proj", "d", "repo", "service", "public")
	}
}

func publishRelease(cur realm, projectID, version, digest string) string {
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	id := rel.CreateRelease(cross(cur), projectID, version, "abc1234", "main", "", "")
	rel.SetEvidence(cross(cur), id, digest)
	rel.MarkValidating(cross(cur), id)
	rel.Approve(cross(cur), id)
	rel.Publish(cross(cur), id)
	return id
}

func TestFullVerificationWorkflow(cur realm, t *testing.T) {
	seed(cur)

	// publish a release
	rid := publishRelease(cur, "vf-proj", "1.0.0", digestA)

	// baseline: no policy, no build attestation -> PENDING with failing baseline check
	v := VerifyRelease(rid)
	if v.Verdict != VerdictPending {
		t.Fatalf("expected PENDING before attestations, got %s", v.Verdict)
	}
	if len(v.PolicyChecks) != 1 || v.PolicyChecks[0].Passed {
		t.Fatal("baseline check should fail without build attestation")
	}
	if v.ArtifactDigest != digestA {
		t.Fatal("digest not surfaced")
	}

	// issuer attests build provenance
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	att.Issue(cross(cur), core.SubjectRelease, rid, core.AttestBuild, digestB, 0)

	v = VerifyRelease(rid)
	if v.Verdict != VerdictVerified {
		t.Fatalf("expected VERIFIED after baseline attestation, got %s (%+v)", v.Verdict, v.PolicyChecks)
	}
	if len(v.Attestations) != 1 || v.Attestations[0].Category != core.AttestBuild {
		t.Fatal("attestation summary missing")
	}

	// digest lookup works for external consumers
	found := VerifyDigest(digestA)
	if len(found) != 1 || found[0] != rid {
		t.Fatalf("digest lookup failed: %v", found)
	}
}

func TestPolicyEnforcedVerification(cur realm, t *testing.T) {
	seedProjectID(cur, "pol-vf-proj")
	rid := publishRelease(cur, "pol-vf-proj", "2.0.0", digestA)

	// project owner sets a strict policy
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	pol.SetPolicy(cross(cur), "pol-vf-proj", []string{core.AttestBuild, core.AttestSecurity}, 1, []string{string(bobAddr)}, true, true)

	// satisfy build only -> PENDING with named failing checks
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	att.Issue(cross(cur), core.SubjectRelease, rid, core.AttestBuild, digestB, 0)

	v := VerifyRelease(rid)
	if v.Verdict != VerdictPending {
		t.Fatalf("expected PENDING under strict policy, got %s", v.Verdict)
	}
	failed := 0
	for _, c := range v.PolicyChecks {
		if !c.Passed {
			failed++
		}
	}
	if failed != 4 { // security attestation + approvals + no-critical + sbom
		t.Fatalf("expected 4 failing checks, got %d (%+v)", failed, v.PolicyChecks)
	}
	if v.PolicyVersion != 1 {
		t.Fatal("policy version not surfaced")
	}

	// approvals from a NON-allowlisted issuer must not count
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	att.Issue(cross(cur), core.SubjectRelease, rid, core.AttestReleaseApprove, digestC, 0)
	v = VerifyRelease(rid)
	for _, c := range v.PolicyChecks {
		if c.Requirement == "APPROVALS>=1" && c.Passed {
			t.Fatal("non-allowlisted approval must not count")
		}
	}

	// allowlisted issuer approves + security + dependency attestations
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	att.Issue(cross(cur), core.SubjectRelease, rid, core.AttestReleaseApprove, digestC, 0)
	att.Issue(cross(cur), core.SubjectRelease, rid, core.AttestSecurity, digestB, 0)
	att.Issue(cross(cur), core.SubjectRelease, rid, core.AttestDependency, digestB, 0)

	v = VerifyRelease(rid)
	if v.Verdict != VerdictVerified {
		t.Fatalf("expected VERIFIED under policy, got %s (%+v)", v.Verdict, v.PolicyChecks)
	}
}

func TestRevocationVisibleInVerdict(cur realm, t *testing.T) {
	seedProjectID(cur, "rv-vf-proj")
	rid := publishRelease(cur, "rv-vf-proj", "3.0.0", digestA)

	testing.SetRealm(testing.NewUserRealm(bobAddr))
	attID := att.Issue(cross(cur), core.SubjectRelease, rid, core.AttestBuild, digestB, 0)
	v := VerifyRelease(rid)
	if v.Verdict != VerdictVerified {
		t.Fatalf("expected VERIFIED, got %s", v.Verdict)
	}

	// revoke the release itself: verdict becomes REVOKED and stays inspectable
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	rel.Revoke(cross(cur), rid)
	v = VerifyRelease(rid)
	if v.Verdict != VerdictRevoked {
		t.Fatalf("expected REVOKED verdict, got %s", v.Verdict)
	}
	if len(v.Attestations) == 0 {
		t.Fatal("attestations must remain listed on revoked releases")
	}

	// revoking the attestation flips its status; the release stays revoked
	testing.SetRealm(testing.NewUserRealm(bobAddr))
	att.Revoke(cross(cur), attID, "bad evidence")
	sum, st := VerifyAttestation(attID)
	if st != core.AttestationRevoked || sum.Status != core.AttestationRevoked {
		t.Fatalf("attestation revocation not visible: %s", st)
	}
	v = VerifyRelease(rid)
	if v.Verdict != VerdictRevoked {
		t.Fatal("release verdict must stay revoked")
	}
	if v.Attestations[0].Status != core.AttestationRevoked {
		t.Fatal("attestation summary must show revoked")
	}
}

func TestUnknownAndPrePublication(cur realm, t *testing.T) {
	seedProjectID(cur, "unk-vf-proj")

	if v := VerifyRelease("ghost-release-9.9.9"); v.Verdict != VerdictUnknown {
		t.Fatalf("unknown release verdict wrong: %s", v.Verdict)
	}

	// draft release (not published): PENDING, hidden details for foreigners
	testing.SetRealm(testing.NewUserRealm(aliceAddr))
	rel.CreateRelease(cross(cur), "unk-vf-proj", "9.9.9-rc", "abc1234", "dev", "", "")
	v := VerifyRelease("unk-vf-proj-9.9.9-rc")
	if v.Verdict != VerdictPending {
		t.Fatalf("pre-publication verdict wrong: %s", v.Verdict)
	}
	if v.ArtifactDigest != "" {
		t.Fatal("pre-publication verdict must not leak evidence details")
	}

	if _, st := VerifyAttestation("no-such-att"); st != "" {
		t.Fatal("unknown attestation should have empty status")
	}
}

func TestComposabilitySurface(cur realm, t *testing.T) {
	seed(cur)

	// public listing + stats reflect real state
	ids := ListPublicProjectIDs()
	found := false
	for _, id := range ids {
		if id == "vf-proj" {
			found = true
		}
	}
	if !found {
		t.Fatal("public project not listed")
	}

	p, ok := GetProject("vf-proj")
	if !ok || p.Owner != aliceAddr {
		t.Fatalf("public project record wrong: %v", ok)
	}

	projects, components, releases, attestations := RegistryStats()
	if projects == 0 || releases == 0 {
		t.Fatalf("stats broken: %d %d %d %d", projects, components, releases, attestations)
	}

	if ProtocolVersion() != core.ProtocolVersion {
		t.Fatal("protocol version mismatch")
	}
}
