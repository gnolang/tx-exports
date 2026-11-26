package oathledger

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

const realmPath = "gno.land/r/g1ty0rp975ndkcse760v0zt659f4phs4z8lueud7/oathledger"

func resetState() {
	pacts = *avl.NewTree()
	builders = *avl.NewTree()
	nextPactID = 1
	totalEscrowedUgnot = 0
	activeLockedUgnot = 0
	totalReleasedUgnot = 0
	completedPactsCount = 0
	disputedPactsCount = 0
}

func TestFullMultiMilestoneQuorumLifecycle(cur realm, t *testing.T) {
	defer resetState()

	pkgAddr := chain.PackageAddress(realmPath)
	sponsor := testutils.TestAddress("sponsor1")
	builder := testutils.TestAddress("builder1")
	rev1 := testutils.TestAddress("reviewer1")
	rev2 := testutils.TestAddress("reviewer2")
	rev3 := testutils.TestAddress("reviewer3")
	outsider := testutils.TestAddress("outsider1")

	escrowAmt := int64(10_000_000) // 10 GNOT
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: "ugnot", Amount: escrowAmt}})

	// 1. Sponsor creates a 2-milestone pact (40% / 60%) with 2-of-3 quorum
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: escrowAmt}})
	reviewersCSV := rev1.String() + "," + rev2.String() + "," + rev3.String()
	id := CreatePact(
		cross(cur),
		"Zero-Knowledge Merkle Package",
		"Build and audit a pure Gno Merkle proof verifier.",
		"Spec & Math,Realm & Audit",
		"4000,6000",
		reviewersCSV,
		2,
		72,
	)
	uassert.Equal(t, int64(1), id)
	uassert.Equal(t, escrowAmt, activeLockedUgnot)

	// Sponsor cannot self-claim to farm PoC XP
	uassert.AbortsWithMessage(t, cur, "sponsor cannot claim own pact", func() {
		ClaimPact(cross(cur), id)
	})

	// 2. Builder claims pact and submits Milestone 0
	testing.SetRealm(testing.NewUserRealm(builder))
	ClaimPact(cross(cur), id)
	SubmitMilestone(cross(cur), id, 0, "https://github.com/org/repo/commit/abc123")

	// Outsider cannot approve
	testing.SetRealm(testing.NewUserRealm(outsider))
	uassert.AbortsWithMessage(t, cur, "caller is not a designated reviewer", func() {
		ApproveMilestone(cross(cur), id, 0)
	})

	// 3. Reviewer 1 votes (1/2 quorum -> no payout yet)
	testing.SetRealm(testing.NewUserRealm(rev1))
	ApproveMilestone(cross(cur), id, 0)
	uassert.Equal(t, int64(0), totalReleasedUgnot)

	// Duplicate vote rejected
	uassert.AbortsWithMessage(t, cur, "reviewer already approved this milestone", func() {
		ApproveMilestone(cross(cur), id, 0)
	})

	// 4. Reviewer 2 casts deciding vote (2/2 quorum -> 4 GNOT atomically released!)
	testing.SetRealm(testing.NewUserRealm(rev2))
	ApproveMilestone(cross(cur), id, 0)
	uassert.Equal(t, int64(4_000_000), totalReleasedUgnot)
	uassert.Equal(t, int64(6_000_000), activeLockedUgnot)

	roBanker := banker.NewReadonlyBanker()
	uassert.Equal(t, int64(4_000_000), roBanker.GetCoin(builder, "ugnot"))

	// 5. Complete Milestone 1 (6 GNOT) -> pact transitions to COMPLETED
	testing.SetRealm(testing.NewUserRealm(builder))
	SubmitMilestone(cross(cur), id, 1, "https://github.com/org/repo/commit/def456")
	testing.SetRealm(testing.NewUserRealm(rev1))
	ApproveMilestone(cross(cur), id, 1)
	testing.SetRealm(testing.NewUserRealm(rev3))
	ApproveMilestone(cross(cur), id, 1)

	uassert.Equal(t, int64(10_000_000), totalReleasedUgnot)
	uassert.Equal(t, int64(0), activeLockedUgnot)
	uassert.Equal(t, int64(1), completedPactsCount)
	uassert.Equal(t, int64(10_000_000), roBanker.GetCoin(builder, "ugnot"))
	uassert.True(t, GetBuilderXP(builder) >= 400, "xp")

	// Verify multi-route Render output
	home := Render("")
	uassert.True(t, strings.Contains(home, "OathLedger"), "home title")
	uassert.True(t, strings.Contains(home, "COMPLETED"), "home completed")
	detail := Render("pact/1")
	uassert.True(t, strings.Contains(detail, "Merkle Package"), "detail title")
	uassert.True(t, strings.Contains(detail, "10.000000 GNOT"), "detail amount")
	lb := Render("leaderboard")
	uassert.True(t, strings.Contains(lb, builder.String()), "lb builder")
	prof := Render("builder/" + builder.String())
	uassert.True(t, strings.Contains(prof, "10.000000 GNOT"), "prof amount")
}

func TestTrustlessQuorumDisputeResolution(cur realm, t *testing.T) {
	defer resetState()

	pkgAddr := chain.PackageAddress(realmPath)
	sponsor := testutils.TestAddress("sponsor_d")
	builder := testutils.TestAddress("builder_d")
	rev1 := testutils.TestAddress("rev_d1")
	rev2 := testutils.TestAddress("rev_d2")

	escrowAmt := int64(5_000_000)
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: "ugnot", Amount: escrowAmt}})

	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: escrowAmt}})
	id := CreatePact(cross(cur), "Disputed Task", "Test quorum arbitration.", "Full Delivery", "10000", rev1.String()+","+rev2.String(), 2, 48)

	testing.SetRealm(testing.NewUserRealm(builder))
	ClaimPact(cross(cur), id)
	RaiseDispute(cross(cur), id, "Scope changed mid-sprint")

	// Reviewers agree on 60% builder / 40% sponsor split
	testing.SetRealm(testing.NewUserRealm(rev1))
	VoteDisputeResolution(cross(cur), id, 6000)
	testing.SetRealm(testing.NewUserRealm(rev2))
	VoteDisputeResolution(cross(cur), id, 6000)

	roBanker := banker.NewReadonlyBanker()
	uassert.Equal(t, int64(3_000_000), roBanker.GetCoin(builder, "ugnot"))
	uassert.Equal(t, int64(2_000_000), roBanker.GetCoin(sponsor, "ugnot"))
	uassert.Equal(t, int64(0), activeLockedUgnot)
}

func TestDeadlineExpiryReclaim(cur realm, t *testing.T) {
	defer resetState()

	pkgAddr := chain.PackageAddress(realmPath)
	sponsor := testutils.TestAddress("sponsor_e")
	rev1 := testutils.TestAddress("rev_e1")

	escrowAmt := int64(2_000_000)
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: "ugnot", Amount: escrowAmt}})

	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: escrowAmt}})
	id := CreatePact(cross(cur), "Expired Bounty", "Testing safe timeout refund.", "Deliverable", "10000", rev1.String(), 1, 2)

	// Cannot reclaim before deadline
	uassert.AbortsWithMessage(t, cur, "pact deadline has not passed yet", func() {
		ReclaimExpired(cross(cur), id)
	})

	// Simulate deadline passing and reclaim cleanly
	pact := mustGetPact(id)
	pact.Deadline = time.Now().Add(-1 * time.Minute)
	ReclaimExpired(cross(cur), id)

	roBanker := banker.NewReadonlyBanker()
	uassert.Equal(t, escrowAmt, roBanker.GetCoin(sponsor, "ugnot"))
	uassert.Equal(t, int64(0), activeLockedUgnot)
}
