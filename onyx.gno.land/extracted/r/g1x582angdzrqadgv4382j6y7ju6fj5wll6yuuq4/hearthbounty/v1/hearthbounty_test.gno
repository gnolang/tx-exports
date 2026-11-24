package hearthbounty

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthcore/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/gnoland/wugnot"
)

const (
	testRealmPath = "gno.land/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v1"
	wugnotPkgPath = "gno.land/r/gnoland/wugnot"
)

func resetState(initialArbiter address) {
	arbiter = initialArbiter
	realmAddress = chain.PackageAddress(testRealmPath)
	realmPkgPath = testRealmPath
	realmWebBase = "/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v1"
	bountySeq = 0
	bounties = avl.NewTree()
	profiles = avl.NewTree()
	openCount = 0
	claimedCount = 0
	submittedCount = 0
	disputedCount = 0
	settledCount = 0
	cancelledCount = 0
	agentCount = 0
	totalEscrowUgnot = 0
	totalSettledUgnot = 0
	totalRefundUgnot = 0
	initRouter()
}

func prepCoins(user address, amount int64) {
	wugnotAddr := chain.PackageAddress(wugnotPkgPath)
	testing.SetOriginCaller(user)
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: amount}})
	testing.IssueCoins(wugnotAddr, chain.Coins{{Denom: "ugnot", Amount: amount}})
}

func assertEscrowInvariant(t *testing.T, realmAddr address, initialRealmBal int64) {
	t.Helper()
	uassert.Equal(t, initialRealmBal+totalEscrowUgnot, EscrowBalance(realmAddr))
}

func TestFullBountyLifecycleAndReputation(cur realm, t *testing.T) {
	arb := testutils.TestAddress("arbiter")
	sponsor := testutils.TestAddress("sponsor")
	agent := testutils.TestAddress("agent_hunter")
	donor := testutils.TestAddress("crowdfund_donor")
	realmAddr := chain.PackageAddress(testRealmPath)

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)
	baseRealmBal := EscrowBalance(realmAddr)

	testing.SetRealm(testing.NewUserRealm(agent))
	RegisterProfile(cross(cur), "anvil-ai", "Autonomous Gno realm builder", "gno,audit,mcp", "mcp://anvil.local")
	prof, ok := GetProfile(agent)
	uassert.True(t, ok)
	uassert.True(t, prof.IsAgent)
	uassert.Equal(t, "anvil-ai", prof.Handle)
	uassert.Equal(t, 1, GetStats().AgentCount)

	testing.SetRealm(testing.NewUserRealm(sponsor))
	prepCoins(sponsor, 2000000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 2000000)
	uassert.Equal(t, int64(2000000), EscrowAllowance(sponsor))

	id := PostBounty(cross(cur), "Build AVL Leaderboard Helper", "Provide a deterministic AVL sorting helper with full unit test coverage.", "realm", 2000000, 200)
	uassert.Equal(t, uint64(1), id)
	uassert.Equal(t, int64(2000000), GetStats().TotalEscrowUgnot)
	assertEscrowInvariant(t, realmAddr, baseRealmBal)

	testing.SetRealm(testing.NewUserRealm(donor))
	prepCoins(donor, 500000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 500000)
	newEscrow := TopUpBounty(cross(cur), id, 500000)
	uassert.Equal(t, int64(2500000), newEscrow)
	uassert.Equal(t, int64(500000), GetDonorContribution(id, donor))
	assertEscrowInvariant(t, realmAddr, baseRealmBal)

	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	uassert.AbortsWithMessage(t, cur, "hearthbounty: sponsor cannot claim own bounty", func() {
		ClaimBounty(cross(cur), id, "self claim")
	})

	testing.SetOriginCaller(agent)
	testing.SetRealm(testing.NewUserRealm(agent))
	ClaimBounty(cross(cur), id, "Claiming via hearthbounty-mcp; ETA 40 blocks.")
	b, ok := GetBounty(id)
	uassert.True(t, ok)
	uassert.Equal(t, string(hearthcore.StatusClaimed), string(b.Status))
	uassert.Equal(t, agent, b.Claimant)

	SubmitProof(cross(cur), id, "https://github.com/hearthbounty/demo/pull/42", "sha256:9f86d081884c7d659a2feaa0c55ad015", "Implemented AVL leaderboard helper and passed all tests.")
	b, _ = GetBounty(id)
	uassert.Equal(t, string(hearthcore.StatusSubmitted), string(b.Status))
	uassert.Equal(t, uint64(1), b.SubmissionCount)
	uassert.Equal(t, b.SubmittedHeight+b.DeadlineBlocks, b.ReviewDeadlineHeight)

	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	RequestRevision(cross(cur), id, "Please add edge-case tests for empty trees.")
	b, _ = GetBounty(id)
	uassert.Equal(t, string(hearthcore.StatusClaimed), string(b.Status))
	uassert.Equal(t, "Please add edge-case tests for empty trees.", b.RevisionFeedback)

	testing.SetOriginCaller(agent)
	testing.SetRealm(testing.NewUserRealm(agent))
	SubmitProof(cross(cur), id, "https://github.com/hearthbounty/demo/pull/42", "sha256:4b227777d4dd1fc61c6f884f48641d02", "Added empty-tree and tie-breaker unit tests.")
	b, _ = GetBounty(id)
	uassert.Equal(t, uint64(2), b.SubmissionCount)

	uassert.AbortsWithMessage(t, cur, "hearthbounty: only the sponsor may approve and settle", func() {
		ApproveAndSettle(cross(cur), id, 5, "unauthorized")
	})

	agentBalBefore := EscrowBalance(agent)
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	ApproveAndSettle(cross(cur), id, 5, "Clean idiomatic Gno code and crisp tests.")

	agentBalAfter := EscrowBalance(agent)
	uassert.Equal(t, agentBalBefore+2500000, agentBalAfter)
	assertEscrowInvariant(t, realmAddr, baseRealmBal)

	b, _ = GetBounty(id)
	uassert.Equal(t, string(hearthcore.StatusSettled), string(b.Status))
	uassert.Equal(t, int64(0), b.EscrowUgnot)
	uassert.Equal(t, int64(2500000), b.PayoutUgnot)
	uassert.Equal(t, uint8(5), b.Rating)

	prof, _ = GetProfile(agent)
	uassert.Equal(t, uint64(1), prof.SettledCount)
	uassert.Equal(t, int64(2500000), prof.EarnedUgnot)
	uassert.Equal(t, uint64(5), prof.RatingSum)
	uassert.Equal(t, uint64(1), prof.RatingCount)
}

// H-1 regression proof: CancelBounty must refund external top-ups strictly to
// their original donors and NEVER transfer third-party coins to the sponsor.
func TestCancelRefundsThirdPartyDonorsWithoutSponsorTheft(cur realm, t *testing.T) {
	arb := testutils.TestAddress("h1_arb")
	sponsor := testutils.TestAddress("h1_sponsor")
	donorA := testutils.TestAddress("h1_donor_a")
	donorB := testutils.TestAddress("h1_donor_b")
	realmAddr := chain.PackageAddress(testRealmPath)

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)
	baseRealmBal := EscrowBalance(realmAddr)

	// Sponsor posts 0.50 GNOT.
	testing.SetRealm(testing.NewUserRealm(sponsor))
	prepCoins(sponsor, 500000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 500000)
	id := PostBounty(cross(cur), "Crowd-Funded Escrow Custody Test", "Verify third-party top-ups are returned to donors on cancel.", "audit", 500000, 100)

	// Donor A tops up 1.50 GNOT in two contributions; Donor B tops up 0.40 GNOT.
	testing.SetRealm(testing.NewUserRealm(donorA))
	prepCoins(donorA, 1500000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 1500000)
	TopUpBounty(cross(cur), id, 1000000)
	TopUpBounty(cross(cur), id, 500000)

	testing.SetRealm(testing.NewUserRealm(donorB))
	prepCoins(donorB, 400000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 400000)
	TopUpBounty(cross(cur), id, 400000)

	// External donor cannot claim the bounty they funded (blocks open->topup->claim wash).
	uassert.AbortsWithMessage(t, cur, "hearthbounty: escrow contributor cannot claim own funded bounty", func() {
		ClaimBounty(cross(cur), id, "wash attempt")
	})

	b, _ := GetBounty(id)
	uassert.Equal(t, int64(2400000), b.EscrowUgnot)
	uassert.Equal(t, int64(500000), b.SponsorFundedUgnot)
	uassert.Equal(t, int64(1900000), b.ExternalTopUpUgnot)
	uassert.Equal(t, 2, b.ExternalDonorCount)

	sponsorBefore := EscrowBalance(sponsor)
	donorABefore := EscrowBalance(donorA)
	donorBBefore := EscrowBalance(donorB)

	// Sponsor cancels -> sponsor receives ONLY their own 0.50 GNOT; donors receive exact refunds.
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	CancelBounty(cross(cur), id)

	uassert.Equal(t, sponsorBefore+500000, EscrowBalance(sponsor))
	uassert.Equal(t, donorABefore+1500000, EscrowBalance(donorA))
	uassert.Equal(t, donorBBefore+400000, EscrowBalance(donorB))
	assertEscrowInvariant(t, realmAddr, baseRealmBal)

	// Phantom SponsoredUgnot credit must be zeroed after full refund.
	spProf, _ := GetProfile(sponsor)
	dAProf, _ := GetProfile(donorA)
	dBProf, _ := GetProfile(donorB)
	uassert.Equal(t, int64(0), spProf.SponsoredUgnot)
	uassert.Equal(t, int64(0), dAProf.SponsoredUgnot)
	uassert.Equal(t, int64(0), dBProf.SponsoredUgnot)
}

// H-1 claimant wash proof: active claimant cannot top up their own claimed bounty.
func TestClaimantCannotWashTopUpIntoEarned(cur realm, t *testing.T) {
	arb := testutils.TestAddress("wash_arb")
	sponsor := testutils.TestAddress("wash_sponsor")
	hunter := testutils.TestAddress("wash_hunter")
	realmAddr := chain.PackageAddress(testRealmPath)

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)

	testing.SetRealm(testing.NewUserRealm(sponsor))
	prepCoins(sponsor, 500000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 500000)
	id := PostBounty(cross(cur), "Wash Guard Check", "Verify active claimant cannot top up own claimed bounty.", "tool", 500000, 50)

	testing.SetOriginCaller(hunter)
	testing.SetRealm(testing.NewUserRealm(hunter))
	ClaimBounty(cross(cur), id, "Claiming")

	uassert.PanicsWithMessage(t, cur, "hearthbounty: active claimant cannot top up own claimed bounty", func() {
		validateTopUpTarget(hunter, id, 200000)
	})
	// Non-origin cross-realm TopUpBounty is also blocked by AssertOriginCall.
	uassert.AbortsWithMessage(t, cur, "invalid non-origin call", func() {
		TopUpBounty(cross(cur), id, 200000)
	})
}

func TestCancelAndExpiredClaimRelease(cur realm, t *testing.T) {
	arb := testutils.TestAddress("arbiter2")
	sponsor := testutils.TestAddress("sponsor2")
	hunter := testutils.TestAddress("hunter2")
	bystander := testutils.TestAddress("bystander2")
	realmAddr := chain.PackageAddress(testRealmPath)

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)
	baseRealmBal := EscrowBalance(realmAddr)

	testing.SetRealm(testing.NewUserRealm(sponsor))
	prepCoins(sponsor, 1000000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 1000000)
	id := PostBounty(cross(cur), "Write gnoweb SVG Guide", "Document deterministic SVG rendering in gnoweb v1.8.", "docs", 1000000, 20)

	testing.SetOriginCaller(hunter)
	testing.SetRealm(testing.NewUserRealm(hunter))
	ClaimBounty(cross(cur), id, "On it")
	SubmitProof(cross(cur), id, "https://github.com/hearthbounty/docs/pull/1", "sha256:0123456789abcdef", "Initial draft submitted before revision.")

	// Sponsor requests revision -> back to Claimed with stale proof fields still set until release.
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	RequestRevision(cross(cur), id, "Needs cleaner examples.")

	uassert.AbortsWithMessage(t, cur, "hearthbounty: only open bounties can be cancelled", func() {
		CancelBounty(cross(cur), id)
	})

	testing.SetOriginCaller(bystander)
	testing.SetRealm(testing.NewUserRealm(bystander))
	uassert.AbortsWithMessage(t, cur, "hearthbounty: claim deadline has not expired yet", func() {
		ReleaseExpiredClaim(cross(cur), id)
	})

	// Advance exactly to DeadlineHeight (20 blocks) -> bystander can release on exact deadline block.
	testing.SkipHeights(20)
	ReleaseExpiredClaim(cross(cur), id)
	b, _ := GetBounty(id)
	uassert.Equal(t, string(hearthcore.StatusOpen), string(b.Status))
	uassert.Equal(t, address(""), b.Claimant)
	uassert.Equal(t, "", b.ProofURL)
	uassert.Equal(t, "", b.ProofDigest)
	uassert.Equal(t, "", b.ProofSummary)

	// ClaimedCount must be decremented on release so claim-and-release cannot inflate it.
	hp, _ := GetProfile(hunter)
	uassert.Equal(t, uint64(0), hp.ClaimedCount)

	sponsorBalBefore := EscrowBalance(sponsor)
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	CancelBounty(cross(cur), id)

	uassert.Equal(t, sponsorBalBefore+1000000, EscrowBalance(sponsor))
	assertEscrowInvariant(t, realmAddr, baseRealmBal)
	uassert.Equal(t, int64(1000000), GetStats().TotalRefundUgnot)
}

// M-1 proof #1: ExpireSubmission prevents sponsors from holding delivered proofs hostage.
func TestSubmissionReviewTimeoutAutoSettle(cur realm, t *testing.T) {
	arb := testutils.TestAddress("m1_arb")
	sponsor := testutils.TestAddress("m1_sponsor")
	hunter := testutils.TestAddress("m1_hunter")
	bystander := testutils.TestAddress("m1_bystander")
	realmAddr := chain.PackageAddress(testRealmPath)

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)
	baseRealmBal := EscrowBalance(realmAddr)

	testing.SetRealm(testing.NewUserRealm(sponsor))
	prepCoins(sponsor, 1200000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 1200000)
	id := PostBounty(cross(cur), "Review Timeout Test", "Verify ExpireSubmission settles 100% after review deadline.", "realm", 1200000, 30)

	testing.SetOriginCaller(hunter)
	testing.SetRealm(testing.NewUserRealm(hunter))
	ClaimBounty(cross(cur), id, "Working on review timeout test")
	SubmitProof(cross(cur), id, "https://github.com/hearthbounty/v1/pull/7", "sha256:fedcba9876543210", "Delivered complete solution and test suite.")

	// Cannot expire before ReviewDeadlineHeight.
	testing.SetOriginCaller(bystander)
	testing.SetRealm(testing.NewUserRealm(bystander))
	uassert.AbortsWithMessage(t, cur, "hearthbounty: submission review window has not expired yet", func() {
		ExpireSubmission(cross(cur), id)
	})

	// Advance to exact ReviewDeadlineHeight -> bystander triggers permissionless settlement.
	hunterBefore := EscrowBalance(hunter)
	testing.SkipHeights(30)
	ExpireSubmission(cross(cur), id)

	uassert.Equal(t, hunterBefore+1200000, EscrowBalance(hunter))
	assertEscrowInvariant(t, realmAddr, baseRealmBal)
	b, _ := GetBounty(id)
	uassert.Equal(t, string(hearthcore.StatusSettled), string(b.Status))
	uassert.Equal(t, int64(1200000), b.PayoutUgnot)
}

// M-1 proof #2 + H-1 pro-rata dispute proof:
// - Arbiter cannot resolve a bounty where arbiter == sponsor or arbiter == claimant.
// - Dispute split refunds third-party donors pro-rata instead of sending their refund to sponsor.
// - ExpireDispute triggers a permissionless 50/50 split if the arbiter stalls or is conflicted.
func TestDisputeSplitConflictGuardAndTimeoutFallback(cur realm, t *testing.T) {
	arb := testutils.TestAddress("arbiter3")
	arb2 := testutils.TestAddress("arbiter3_new")
	sponsor := testutils.TestAddress("sponsor3")
	donor := testutils.TestAddress("donor3")
	hunter := testutils.TestAddress("hunter3")
	bystander := testutils.TestAddress("bystander3")
	realmAddr := chain.PackageAddress(testRealmPath)

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)
	baseRealmBal := EscrowBalance(realmAddr)

	SetArbiter(cross(cur), arb2)
	uassert.Equal(t, arb2, Arbiter())

	// Bounty 1: 1.00 GNOT sponsor + 0.50 GNOT donor -> 70/30 dispute split.
	testing.SetRealm(testing.NewUserRealm(sponsor))
	prepCoins(sponsor, 1000000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 1000000)
	id1 := PostBounty(cross(cur), "Audit Interrealm Payment Guard", "Check all crossing guards and produce formal report.", "audit", 1000000, 40)

	testing.SetRealm(testing.NewUserRealm(donor))
	prepCoins(donor, 500000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 500000)
	TopUpBounty(cross(cur), id1, 500000)

	testing.SetOriginCaller(hunter)
	testing.SetRealm(testing.NewUserRealm(hunter))
	ClaimBounty(cross(cur), id1, "Auditing now")
	SubmitProof(cross(cur), id1, "https://github.com/hearthbounty/audit/blob/main/report.md", "sha256:abcdef0123456789", "Delivered partial audit covering 70% of scope.")
	OpenDispute(cross(cur), id1, "Core findings delivered; requesting 70/30 partial settlement.")

	testing.SetOriginCaller(arb)
	testing.SetRealm(testing.NewUserRealm(arb))
	uassert.AbortsWithMessage(t, cur, "hearthbounty: only the arbiter may resolve disputes", func() {
		ResolveDispute(cross(cur), id1, 7000, "unauthorized")
	})

	hunterBalBefore := EscrowBalance(hunter)
	sponsorBalBefore := EscrowBalance(sponsor)
	donorBalBefore := EscrowBalance(donor)

	testing.SetOriginCaller(arb2)
	testing.SetRealm(testing.NewUserRealm(arb2))
	ResolveDispute(cross(cur), id1, 7000, "70% of specification verified; 30% refunded pro-rata.")

	// 70% of 1.50 GNOT = 1.05 GNOT hunter; 30% of 1.00 GNOT = 0.30 GNOT sponsor; 30% of 0.50 GNOT = 0.15 GNOT donor.
	uassert.Equal(t, hunterBalBefore+1050000, EscrowBalance(hunter))
	uassert.Equal(t, sponsorBalBefore+300000, EscrowBalance(sponsor))
	uassert.Equal(t, donorBalBefore+150000, EscrowBalance(donor))
	assertEscrowInvariant(t, realmAddr, baseRealmBal)

	// Bounty 2: Arbiter IS the claimant -> conflicted arbiter blocked, ExpireDispute falls back to 50/50.
	testing.SetRealm(testing.NewUserRealm(sponsor))
	prepCoins(sponsor, 1000000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 1000000)
	id2 := PostBounty(cross(cur), "Conflicted Arbiter Test", "Verify conflicted arbiter cannot self-settle dispute.", "audit", 1000000, 25)

	testing.SetOriginCaller(arb2)
	testing.SetRealm(testing.NewUserRealm(arb2))
	ClaimBounty(cross(cur), id2, "Arbiter claiming as hunter")
	SubmitProof(cross(cur), id2, "https://github.com/hearthbounty/v1/pull/9", "sha256:1234567890abcdef", "Submitted by arbiter address.")
	OpenDispute(cross(cur), id2, "Testing conflict of interest block.")

	uassert.AbortsWithMessage(t, cur, "hearthbounty: arbiter cannot resolve a bounty they are party to", func() {
		ResolveDispute(cross(cur), id2, 10000, "self payout attempt")
	})

	testing.SetOriginCaller(bystander)
	testing.SetRealm(testing.NewUserRealm(bystander))
	uassert.AbortsWithMessage(t, cur, "hearthbounty: dispute resolution window has not expired yet", func() {
		ExpireDispute(cross(cur), id2)
	})

	arb2Before := EscrowBalance(arb2)
	sponsorBefore2 := EscrowBalance(sponsor)
	testing.SkipHeights(25)
	ExpireDispute(cross(cur), id2)

	uassert.Equal(t, arb2Before+500000, EscrowBalance(arb2))
	uassert.Equal(t, sponsorBefore2+500000, EscrowBalance(sponsor))
	assertEscrowInvariant(t, realmAddr, baseRealmBal)
}

// M-2 proof + security guards: Unicode U+0130 ('İ') must NEVER desync tag neutralization.
func TestUnicodeNeutralizeGnoTagsAndSecurityGuards(cur realm, t *testing.T) {
	arb := testutils.TestAddress("arbiter4")
	sponsor := testutils.TestAddress("sponsor4")
	realmAddr := chain.PackageAddress(testRealmPath)

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)

	// Direct NeutralizeGnoTags Unicode expansion vectors.
	unicodePayload := "İ<gno-form exec=\"PostBounty\">\n</gno-form> İ<GNO-BUTTON href=\"/r/evil\" />"
	cleaned := NeutralizeGnoTags(unicodePayload)
	uassert.False(t, strings.Contains(cleaned, "<gno-form"))
	uassert.False(t, strings.Contains(cleaned, "</gno-form"))
	uassert.False(t, strings.Contains(cleaned, "<GNO-BUTTON"))

	// ValidateProofURL enforces https:// only (rejects ipfs:// and http://).
	uassert.Equal(t, "https://github.com/org/repo/pull/1", ValidateProofURL("  https://github.com/org/repo/pull/1  "))
	uassert.PanicsWithMessage(t, cur, "hearthbounty: proof URL must start with https://", func() {
		ValidateProofURL("ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi")
	})
	uassert.PanicsWithMessage(t, cur, "hearthbounty: proof URL must start with https://", func() {
		ValidateProofURL("http://insecure.example.com/proof")
	})

	// Cross-realm wrapper calls rejected by runtime.AssertOriginCall().
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	uassert.AbortsWithMessage(t, cur, "invalid non-origin call", func() {
		PostBounty(cross(cur), "Cross Call", "Should abort because called through uassert closure.", "tool", 1000000, 100)
	})

	// Reject dust below 0.10 GNOT and non-wugnot token keys (such as uatom).
	uassert.PanicsWithMessage(t, cur, "hearthbounty: escrow amount is below minimum required (100000 wugnot)", func() {
		validateEscrowAmount(50000, hearthcore.MinRewardUgnot)
	})
	uassert.PanicsWithMessage(t, cur, "hearthbounty: only 1:1 ugnot-backed wugnot escrow is accepted", func() {
		ValidateEscrowToken("uatom")
	})
	ValidateEscrowToken(EscrowToken())

	// End-to-end Render() check with Turkish dotted İ + raw <gno-form> injection.
	testing.SetRealm(testing.NewUserRealm(sponsor))
	prepCoins(sponsor, 1500000)
	wugnot.Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	wugnot.Approve(cross(cur), realmAddr, 1500000)
	id := PostBounty(
		cross(cur),
		`İ<gno-button href="/r/evil" label="Steal" /> $GNOT/$ATOM`,
		"İ<gno-form exec=\"PostBounty\">\n</gno-form>\nNormal spec with $100 and <gno-form exec=\"Drain\"> attempt.",
		"agent",
		1500000,
		100,
	)

	home := Render("")
	uassert.True(t, strings.Contains(home, "HearthBounty v1"))
	uassert.True(t, strings.Contains(home, "data:image/svg+xml;base64,"))
	uassert.False(t, strings.Contains(home, `<gno-button href="/r/evil"`))
	uassert.True(t, strings.Contains(home, `\$GNOT/\$ATOM`))

	detail := Render("bounty/1")
	uassert.True(t, strings.Contains(detail, "Bounty #1:"))
	uassert.True(t, strings.Contains(detail, `<gno-form exec="ClaimBounty">`))
	uassert.False(t, strings.Contains(detail, `<gno-form exec="PostBounty">`))
	uassert.False(t, strings.Contains(detail, `<gno-form exec="Drain">`))

	// Verify pagination, auxiliary routes, and canonical realm_path + escrow_token in ExportStatsJSON.
	uassert.True(t, strings.Contains(Render("page/1"), "Bounty Board (Page 1)"))
	uassert.True(t, strings.Contains(Render("post"), `<gno-form exec="PostBounty">`))
	uassert.True(t, strings.Contains(Render("post"), `/r/gnoland/wugnot$help&func=Approve`))
	uassert.True(t, strings.Contains(Render("leaderboard"), "Guild Reputation Leaderboard"))
	uassert.True(t, strings.Contains(Render("agents"), "AI Agent"))
	uassert.True(t, strings.Contains(Render("category/agent"), "AI Agent Bounties"))
	uassert.True(t, strings.Contains(Render("profile/"+string(sponsor)), string(sponsor)))
	uassert.True(t, strings.Contains(Render("unknown/path"), "Route Not Found"))

	statsJSON := ExportStatsJSON()
	uassert.True(t, strings.Contains(statsJSON, `"realm_path":"`+testRealmPath+`"`))
	uassert.True(t, strings.Contains(statsJSON, `"escrow_token":"`+EscrowTokenKey+`"`))
	uassert.True(t, strings.Contains(statsJSON, `"escrow_address":"`+string(realmAddr)+`"`))
	uassert.True(t, strings.Contains(statsJSON, `"total_bounties":1`))
	bountyJSON := ExportBountyJSON(id)
	uassert.True(t, strings.Contains(bountyJSON, `"found":true`))
	uassert.True(t, strings.Contains(bountyJSON, `"sponsor_funded_ugnot":1500000`))
	listJSON := ExportBountiesJSON("open", "agent", 1000000, 10)
	uassert.True(t, strings.Contains(listJSON, `"count":1`))
	lbJSON := ExportLeaderboardJSON(10)
	uassert.True(t, strings.Contains(lbJSON, `"count":1`))
}
