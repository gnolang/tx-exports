package ironclad

import (
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func resetState() {
	auditors = avl.NewTree()
	handleIndex = avl.NewTree()
	attestations = avl.NewTree()
	pkgIndex = avl.NewTree()
	latestByPkgAuditor = avl.NewTree()
	pkgAttestations = avl.NewTree()
	auditorDigestIndex = avl.NewTree()
	digestFirstIndex = avl.NewTree()
	challenges = avl.NewTree()
	attChallenges = avl.NewTree()
	challengeDedup = avl.NewTree()
	nextAttestID = 0
	nextChallengeID = 0
}

func TestRegressionAllFable52Findings(cur realm, t *testing.T) {
	defer resetState()

	auditor1 := testutils.TestAddress("auditor1")
	auditor2 := testutils.TestAddress("auditor2")
	researcher := testutils.TestAddress("researcher1")
	srcHash := "1111111111111111111111111111111111111111111111111111111111111111"
	repHash := "2222222222222222222222222222222222222222222222222222222222222222"
	evHash := "3333333333333333333333333333333333333333333333333333333333333333"

	// P1: Unique auditor handles
	testing.SetRealm(testing.NewUserRealm(auditor1))
	RegisterAuditor(cross(cur), "Ironclad | Core", "Automated auditor", "https://ironclad.example")
	testing.SetRealm(testing.NewUserRealm(auditor2))
	uassert.AbortsWithMessage(t, cur, "ironclad: auditor handle already taken", func() {
		RegisterAuditor(cross(cur), "ironclad | core", "Impersonator", "")
	})
	RegisterAuditor(cross(cur), "SecondAuditor", "Independent reviewer", "")

	// R5: Overflow counts must abort
	uassert.AbortsWithMessage(t, cur, "ironclad: finding counts out of bounds (0..100000)", func() {
		PublishAttestation(cross(cur), "gno.land/r/demo/vault", srcHash, repHash, "ironclad-1.0.0", 0, 0, 0, 100001, 0, "", "overflow", "")
	})

	// R8: Invalid rulesTriggered charset/token must abort
	uassert.AbortsWithMessage(t, cur, "ironclad: invalid rulesTriggered (must be comma-separated known rule IDs)", func() {
		PublishAttestation(cross(cur), "gno.land/r/demo/vault", srcHash, repHash, "ironclad-1.0.0", 1, 0, 0, 0, 0, "GNO-TC2|`evil`", "bad rules", "")
	})

	// R2 & R3: Auditor 1 publishes F (2 criticals), Auditor 2 publishes SAME digest & A+ without collision or hijacking Auditor 1
	testing.SetRealm(testing.NewUserRealm(auditor1))
	id1 := PublishAttestation(cross(cur), "gno.land/r/demo/vault", srcHash, repHash, "ironclad-1.0.0", 2, 0, 0, 0, 0, "GNO-TC2,GNO-SEC01", "Critical auth bugs [click](https://evil.example)", "")
	uassert.Equal(t, uint64(1), id1)

	// Same auditor duplicate active digest must fail
	uassert.AbortsWithMessage(t, cur, "ironclad: you already published an active identical attestation", func() {
		PublishAttestation(cross(cur), "gno.land/r/demo/vault", srcHash, repHash, "ironclad-1.0.0", 2, 0, 0, 0, 0, "GNO-TC2,GNO-SEC01", "dup", "")
	})

	// R3: Second auditor publishing identical digest succeeds (no squatting)
	testing.SetRealm(testing.NewUserRealm(auditor2))
	id2 := PublishAttestation(cross(cur), "gno.land/r/demo/vault", srcHash, repHash, "ironclad-1.0.0", 2, 0, 0, 0, 0, "GNO-TC2,GNO-SEC01", "Independent confirmation", "")
	uassert.Equal(t, uint64(2), id2)

	// R1: Render("attestation/1") MUST render Attestation #1, NOT #2!
	att1Page := Render("attestation/1")
	uassert.True(t, strings.Contains(att1Page, "# Attestation #1"))
	uassert.True(t, strings.Contains(att1Page, auditor1.String()))
	uassert.False(t, strings.Contains(att1Page, "# Attestation #2"))

	// R2: Render("pkg/gno.land/r/demo/vault") shows BOTH auditors
	pkgPage := Render("pkg/gno.land/r/demo/vault")
	uassert.True(t, strings.Contains(pkgPage, "Multi-Auditor Consensus (2 active auditor(s))"))
	uassert.True(t, strings.Contains(pkgPage, "#1"))
	uassert.True(t, strings.Contains(pkgPage, "#2"))

	// R4: Challenge does NOT flip status; validates missedRuleID; supports auditor rebuttal & acceptance
	testing.SetRealm(testing.NewUserRealm(researcher))
	uassert.AbortsWithMessage(t, cur, "ironclad: unknown missedRuleID (must match official Ironclad taxonomy rule)", func() {
		ChallengeAttestation(cross(cur), id1, "FAKE-999", evHash, "invalid rule")
	})
	ch1 := ChallengeAttestation(cross(cur), id1, "GNO-TC3", evHash, "Missed unchecked interface param")
	uassert.Equal(t, uint64(1), ch1)

	att1AfterCh, _ := GetAttestation(id1)
	uassert.Equal(t, StatusValid, att1AfterCh.Status) // NOT flipped by anonymous griefing!
	uassert.Equal(t, 1, att1AfterCh.OpenChallenges)
	cv, ok := GetChallenge(ch1)
	urequire.True(t, ok)
	uassert.Equal(t, ChallengeOpen, cv.Status)

	// Auditor 1 rebuts ch1
	testing.SetRealm(testing.NewUserRealm(auditor1))
	RespondToChallenge(cross(cur), ch1, false, "Interface is checked via type switch on line 44")
	cvAfter, _ := GetChallenge(ch1)
	uassert.Equal(t, ChallengeRebutted, cvAfter.Status)
	att1AfterRebut, _ := GetAttestation(id1)
	uassert.Equal(t, 0, att1AfterRebut.OpenChallenges)
	uassert.Equal(t, StatusValid, att1AfterRebut.Status)

	// Second challenge accepted -> auto-revokes attestation & displays revokeReason
	testing.SetRealm(testing.NewUserRealm(researcher))
	ch2 := ChallengeAttestation(cross(cur), id1, "AVL001", evHash, "Unbounded Iterate found")
	testing.SetRealm(testing.NewUserRealm(auditor1))
	RespondToChallenge(cross(cur), ch2, true, "Confirmed unbounded loop; revoking for v2")
	att1Rev, _ := GetAttestation(id1)
	uassert.Equal(t, StatusRevoked, att1Rev.Status)
	uassert.True(t, strings.Contains(Render("attestation/1"), "Revocation Reason:"))
	uassert.True(t, strings.Contains(Render("attestation/1"), "AVL001"))

	// R6: Home page has no literal backslash escapes inside code spans
	home := Render("")
	uassert.False(t, strings.Contains(home, `gno\.land`))
	uassert.True(t, strings.Contains(home, "15 Rules"))

	// R7: :json/* escapes Markdown link syntax ([click](...)) as \u005b...\u005d
	jsonOut := Render("json/attestation/1")
	uassert.False(t, strings.Contains(jsonOut, "[click]"))
	uassert.True(t, strings.Contains(jsonOut, `\u005bclick\u005d`))
}

func TestGnowebLinksAndR2Hardening(cur realm, t *testing.T) {
	defer resetState()

	aud1 := testutils.TestAddress("aud_r2_1")
	res1 := testutils.TestAddress("res_r2_1")
	srcHash := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	repHash := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	evHash := "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

	testing.SetRealm(testing.NewUserRealm(aud1))
	id1 := PublishAttestation(cross(cur), "gno.land/r/demo/check", srcHash, repHash, "ironclad-1.0.0", 0, 0, 0, 0, 0, "", "clean pass", "")
	uassert.Equal(t, uint64(1), id1)

	// Duplicate challenge by same challenger for same (att, rule, evidence) must abort
	testing.SetRealm(testing.NewUserRealm(res1))
	ch1 := ChallengeAttestation(cross(cur), id1, "AVL001", evHash, "first report")
	uassert.Equal(t, uint64(1), ch1)
	uassert.AbortsWithMessage(t, cur, "ironclad: duplicate challenge for same attestation, rule, and challenger", func() {
		ChallengeAttestation(cross(cur), id1, "AVL001", evHash, "spam duplicate")
	})

	// Revoke id1 then re-publish same digest -> VerifyAttestationByDigest returns active id2
	testing.SetRealm(testing.NewUserRealm(aud1))
	RevokeAttestation(cross(cur), id1, "superseding")
	id2 := PublishAttestation(cross(cur), "gno.land/r/demo/check", srcHash, repHash, "ironclad-1.0.0", 0, 0, 0, 0, 0, "", "re-published", "")
	uassert.Equal(t, uint64(2), id2)
	att2, _ := GetAttestation(id2)
	gotID, ok := VerifyAttestationByDigest(att2.Digest)
	urequire.True(t, ok)
	uassert.Equal(t, id2, gotID)

	// Zero broken leading-colon gnoweb links across all rendered routes & huge page clamp works
	views := []string{
		Render(""),
		Render("page/999999999999999999"),
		Render("taxonomy"),
		Render("auditors"),
		Render("pkg/gno.land/r/demo/check"),
		Render("attestation/2"),
		Render("nonexistent/path"),
	}
	for _, v := range views {
		uassert.False(t, strings.Contains(v, "](:"))
	}
	uassert.True(t, strings.Contains(views[0], "/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/ironclad:taxonomy"))
	uassert.True(t, strings.Contains(views[0], "$help&func=PublishAttestation"))
}
