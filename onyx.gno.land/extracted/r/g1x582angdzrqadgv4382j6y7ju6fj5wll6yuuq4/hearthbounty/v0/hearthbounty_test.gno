package hearthbounty

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthcore/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func resetState(initialArbiter address) {
	arbiter = initialArbiter
	realmWebBase = "/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v0"
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

func assertEscrowInvariant(t *testing.T, realmAddr address, initialRealmBal int64) {
	t.Helper()
	bnk := banker.NewReadonlyBanker()
	bal := bnk.GetCoin(realmAddr, hearthcore.Denom)
	uassert.Equal(t, initialRealmBal+totalEscrowUgnot, bal)
}

func TestFullBountyLifecycleAndReputation(cur realm, t *testing.T) {
	arb := testutils.TestAddress("arbiter")
	sponsor := testutils.TestAddress("sponsor")
	agent := testutils.TestAddress("agent_hunter")
	donor := testutils.TestAddress("crowdfund_donor")
	realmAddr := chain.PackageAddress("gno.land/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v0")

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)
	baseRealmBal := banker.NewReadonlyBanker().GetCoin(realmAddr, hearthcore.Denom)

	// Register an AI agent profile.
	testing.SetRealm(testing.NewUserRealm(agent))
	RegisterProfile(cross(cur), "anvil-ai", "Autonomous Gno realm builder", "gno,audit,mcp", "mcp://anvil.local")
	prof, ok := GetProfile(agent)
	uassert.True(t, ok)
	uassert.True(t, prof.IsAgent)
	uassert.Equal(t, "anvil-ai", prof.Handle)
	uassert.Equal(t, 1, GetStats().AgentCount)

	// Sponsor posts a 2.00 GNOT bounty.
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 2000000}})
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 2000000}})
	id := PostBounty(cross(cur), "Build AVL Leaderboard Helper", "Provide a deterministic AVL sorting helper with 100% unit test coverage.", "realm", 200)
	uassert.Equal(t, uint64(1), id)
	uassert.Equal(t, int64(2000000), GetStats().TotalEscrowUgnot)
	assertEscrowInvariant(t, realmAddr, baseRealmBal)

	// Supporter tops up +0.50 GNOT.
	testing.SetOriginCaller(donor)
	testing.SetRealm(testing.NewUserRealm(donor))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 500000}})
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 500000}})
	newEscrow := TopUpBounty(cross(cur), id)
	uassert.Equal(t, int64(2500000), newEscrow)
	assertEscrowInvariant(t, realmAddr, baseRealmBal)

	// Sponsor cannot claim own bounty.
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	uassert.AbortsWithMessage(t, cur, "hearthbounty: sponsor cannot claim own bounty", func() {
		ClaimBounty(cross(cur), id, "self claim")
	})

	// Agent claims bounty.
	testing.SetOriginCaller(agent)
	testing.SetRealm(testing.NewUserRealm(agent))
	ClaimBounty(cross(cur), id, "Claiming via hearthbounty-mcp; ETA 40 blocks.")
	b, ok := GetBounty(id)
	uassert.True(t, ok)
	uassert.Equal(t, string(hearthcore.StatusClaimed), string(b.Status))
	uassert.Equal(t, agent, b.Claimant)

	// Agent submits proof.
	SubmitProof(cross(cur), id, "https://github.com/hearthbounty/demo/pull/42", "sha256:9f86d081884c7d659a2feaa0c55ad015", "Implemented AVL leaderboard helper and passed all 18 tests.")
	b, _ = GetBounty(id)
	uassert.Equal(t, string(hearthcore.StatusSubmitted), string(b.Status))
	uassert.Equal(t, uint64(1), b.SubmissionCount)

	// Sponsor requests a revision.
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	RequestRevision(cross(cur), id, "Please add edge-case tests for empty trees.")
	b, _ = GetBounty(id)
	uassert.Equal(t, string(hearthcore.StatusClaimed), string(b.Status))
	uassert.Equal(t, "Please add edge-case tests for empty trees.", b.RevisionFeedback)

	// Agent resubmits revised proof.
	testing.SetOriginCaller(agent)
	testing.SetRealm(testing.NewUserRealm(agent))
	SubmitProof(cross(cur), id, "https://github.com/hearthbounty/demo/pull/42", "sha256:4b227777d4dd1fc61c6f884f48641d02", "Added empty-tree and tie-breaker unit tests.")
	b, _ = GetBounty(id)
	uassert.Equal(t, uint64(2), b.SubmissionCount)

	// Non-sponsor cannot settle.
	uassert.AbortsWithMessage(t, cur, "hearthbounty: only the sponsor may approve and settle", func() {
		ApproveAndSettle(cross(cur), id, 5, "unauthorized")
	})

	// Sponsor approves & settles; verify exact ugnot transfer and reputation update.
	agentBalBefore := banker.NewReadonlyBanker().GetCoin(agent, hearthcore.Denom)
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	ApproveAndSettle(cross(cur), id, 5, "Clean idiomatic Gno code and crisp tests!")

	agentBalAfter := banker.NewReadonlyBanker().GetCoin(agent, hearthcore.Denom)
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

func TestCancelAndExpiredClaimRelease(cur realm, t *testing.T) {
	arb := testutils.TestAddress("arbiter2")
	sponsor := testutils.TestAddress("sponsor2")
	hunter := testutils.TestAddress("hunter2")
	bystander := testutils.TestAddress("bystander2")
	realmAddr := chain.PackageAddress("gno.land/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v0")

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)
	baseRealmBal := banker.NewReadonlyBanker().GetCoin(realmAddr, hearthcore.Denom)

	// Post a bounty with short 20-block claim window.
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	id := PostBounty(cross(cur), "Write gnoweb SVG Guide", "Document deterministic SVG rendering in gnoweb v1.8.", "docs", 20)

	// Hunter claims it.
	testing.SetOriginCaller(hunter)
	testing.SetRealm(testing.NewUserRealm(hunter))
	ClaimBounty(cross(cur), id, "On it")

	// Sponsor cannot cancel while claimed.
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	uassert.AbortsWithMessage(t, cur, "hearthbounty: only open bounties can be cancelled", func() {
		CancelBounty(cross(cur), id)
	})

	// Bystander cannot release before deadline.
	testing.SetOriginCaller(bystander)
	testing.SetRealm(testing.NewUserRealm(bystander))
	uassert.AbortsWithMessage(t, cur, "hearthbounty: claim deadline has not expired yet", func() {
		ReleaseExpiredClaim(cross(cur), id)
	})

	// Advance chain height past deadline -> bystander releases stale claim.
	testing.SkipHeights(25)
	ReleaseExpiredClaim(cross(cur), id)
	b, _ := GetBounty(id)
	uassert.Equal(t, string(hearthcore.StatusOpen), string(b.Status))
	uassert.Equal(t, address(""), b.Claimant)

	// Now sponsor cancels and recovers full 1.00 GNOT escrow.
	sponsorBalBefore := banker.NewReadonlyBanker().GetCoin(sponsor, hearthcore.Denom)
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	CancelBounty(cross(cur), id)

	sponsorBalAfter := banker.NewReadonlyBanker().GetCoin(sponsor, hearthcore.Denom)
	uassert.Equal(t, sponsorBalBefore+1000000, sponsorBalAfter)
	assertEscrowInvariant(t, realmAddr, baseRealmBal)
	uassert.Equal(t, int64(1000000), GetStats().TotalRefundUgnot)
}

func TestDisputeSplitResolutionAndArbiterTransfer(cur realm, t *testing.T) {
	arb := testutils.TestAddress("arbiter3")
	arb2 := testutils.TestAddress("arbiter3_new")
	sponsor := testutils.TestAddress("sponsor3")
	hunter := testutils.TestAddress("hunter3")
	realmAddr := chain.PackageAddress("gno.land/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v0")

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)
	baseRealmBal := banker.NewReadonlyBanker().GetCoin(realmAddr, hearthcore.Denom)

	// Transfer arbiter role.
	SetArbiter(cross(cur), arb2)
	uassert.Equal(t, arb2, Arbiter())

	// Post, claim, submit.
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	id := PostBounty(cross(cur), "Audit Interrealm Payment Guard", "Check all crossing guards and produce formal report.", "audit", 100)

	testing.SetOriginCaller(hunter)
	testing.SetRealm(testing.NewUserRealm(hunter))
	ClaimBounty(cross(cur), id, "Auditing now")
	SubmitProof(cross(cur), id, "https://github.com/hearthbounty/audit/blob/main/report.md", "sha256:abcdef0123456789", "Delivered partial audit covering 70% of scope.")

	// Hunter opens dispute.
	OpenDispute(cross(cur), id, "Core findings delivered; requesting 70/30 partial settlement.")
	b, _ := GetBounty(id)
	uassert.Equal(t, string(hearthcore.StatusDisputed), string(b.Status))

	// Old arbiter cannot resolve.
	testing.SetOriginCaller(arb)
	testing.SetRealm(testing.NewUserRealm(arb))
	uassert.AbortsWithMessage(t, cur, "hearthbounty: only the arbiter may resolve disputes", func() {
		ResolveDispute(cross(cur), id, 7000, "unauthorized")
	})

	// New arbiter resolves 70% hunter / 30% sponsor refund.
	hunterBalBefore := banker.NewReadonlyBanker().GetCoin(hunter, hearthcore.Denom)
	sponsorBalBefore := banker.NewReadonlyBanker().GetCoin(sponsor, hearthcore.Denom)

	testing.SetOriginCaller(arb2)
	testing.SetRealm(testing.NewUserRealm(arb2))
	ResolveDispute(cross(cur), id, 7000, "70% of specification verified; 30% refunded to sponsor.")

	uassert.Equal(t, hunterBalBefore+700000, banker.NewReadonlyBanker().GetCoin(hunter, hearthcore.Denom))
	uassert.Equal(t, sponsorBalBefore+300000, banker.NewReadonlyBanker().GetCoin(sponsor, hearthcore.Denom))
	assertEscrowInvariant(t, realmAddr, baseRealmBal)

	b, _ = GetBounty(id)
	uassert.Equal(t, string(hearthcore.StatusSettled), string(b.Status))
	uassert.Equal(t, int64(700000), b.PayoutUgnot)
	uassert.Equal(t, int64(300000), b.RefundUgnot)
}

func TestSecurityGuardsAndSanitizedRender(cur realm, t *testing.T) {
	arb := testutils.TestAddress("arbiter4")
	sponsor := testutils.TestAddress("sponsor4")
	realmAddr := chain.PackageAddress("gno.land/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v0")

	testing.SetRealm(testing.NewUserRealm(arb))
	resetState(arb)

	// Cross-realm wrapper calls must be rejected by runtime.AssertOriginCall().
	testing.SetOriginCaller(sponsor)
	testing.SetRealm(testing.NewUserRealm(sponsor))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1000000}})
	uassert.AbortsWithMessage(t, cur, "invalid non-origin call", func() {
		PostBounty(cross(cur), "Cross Call", "Should abort because called through uassert closure.", "tool", 100)
	})

	// Reject zero coins, dust below 0.10 GNOT, and unsupported denominations.
	testing.SetOriginSend(chain.Coins{})
	uassert.PanicsWithMessage(t, cur, "hearthbounty: must attach ugnot escrow coins", func() {
		requireSingleUgnotSend(hearthcore.MinRewardUgnot)
	})

	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 50000}})
	uassert.PanicsWithMessage(t, cur, "hearthbounty: attached ugnot is below minimum required amount", func() {
		requireSingleUgnotSend(hearthcore.MinRewardUgnot)
	})

	testing.SetOriginSend(chain.Coins{{Denom: "uatom", Amount: 1000000}})
	uassert.PanicsWithMessage(t, cur, "hearthbounty: only ugnot coins are accepted", func() {
		requireSingleUgnotSend(hearthcore.MinRewardUgnot)
	})

	// Reject markdown button/form/math injection in rendered output.
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1500000}})
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 1500000}})
	id := PostBounty(
		cross(cur),
		`Test <gno-button href="/r/evil" label="Steal" /> $GNOT/$ATOM`,
		"Normal spec with $100 and <gno-form exec=\"Drain\"> attempt.\n<gno-form exec=\"Drain2\">\n</gno-form>",
		"agent",
		100,
	)

	home := Render("")
	uassert.True(t, strings.Contains(home, "HearthBounty"))
	uassert.True(t, strings.Contains(home, "data:image/svg+xml;base64,"))
	uassert.False(t, strings.Contains(home, `<gno-button href="/r/evil"`))
	uassert.True(t, strings.Contains(home, `\$GNOT/\$ATOM`))

	detail := Render("bounty/1")
	uassert.True(t, strings.Contains(detail, "Bounty #1:"))
	uassert.True(t, strings.Contains(detail, `<gno-form exec="ClaimBounty">`))
	uassert.False(t, strings.Contains(detail, `<gno-form exec="Drain">`))

	// Verify all other routes render cleanly.
	uassert.True(t, strings.Contains(Render("post"), `<gno-form exec="PostBounty">`))
	uassert.True(t, strings.Contains(Render("leaderboard"), "Guild Reputation Leaderboard"))
	uassert.True(t, strings.Contains(Render("agents"), "AI Agent"))
	uassert.True(t, strings.Contains(Render("category/agent"), "AI Agent Bounties"))
	uassert.True(t, strings.Contains(Render("profile/"+string(sponsor)), string(sponsor)))
	uassert.True(t, strings.Contains(Render("unknown/path"), "Route Not Found"))

	// Verify JSON export endpoints.
	statsJSON := ExportStatsJSON()
	uassert.True(t, strings.Contains(statsJSON, `"total_bounties":1`))
	bountyJSON := ExportBountyJSON(id)
	uassert.True(t, strings.Contains(bountyJSON, `"found":true`))
	listJSON := ExportBountiesJSON("open", "agent", 1000000, 10)
	uassert.True(t, strings.Contains(listJSON, `"count":1`))
	lbJSON := ExportLeaderboardJSON(10)
	uassert.True(t, strings.Contains(lbJSON, `"count":1`))
}
