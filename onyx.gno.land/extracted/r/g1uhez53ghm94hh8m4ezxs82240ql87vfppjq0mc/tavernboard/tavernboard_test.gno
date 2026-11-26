package tavernboard

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
	"gno.land/p/g1uhez53ghm94hh8m4ezxs82240ql87vfppjq0mc/tavernkit"
)

var (
	alice   = testutils.TestAddress("alice_sponsor")
	bob     = testutils.TestAddress("bob_builder")
	carol   = testutils.TestAddress("carol_cosponsor")
	rev1    = testutils.TestAddress("reviewer_one")
	rev2    = testutils.TestAddress("reviewer_two")
	rev3    = testutils.TestAddress("reviewer_three")
	janitor = testutils.TestAddress("janitor_cleanup")
)

func resetRealmState() {
	nextBountyID = 0
	bounties = avl.NewTree()
	profiles = avl.NewTree()
	statTotalBounties = 0
	statOpenBounties = 0
	statCompletedBounties = 0
	statDisputesResolved = 0
	statTotalFundedUgnot = 0
	statTotalPaidUgnot = 0
	statActiveEscrowUgnot = 0
	statArchivedBounties = 0
}

// attachSend sets the OriginSend envelope and credits this realm's bank balance
// (mirroring Tendermint2 MsgCall coin delivery before entering a crossing func).
// Call testing.SetRealm(testing.NewUserRealm(user)) directly in the test frame
// alongside attachSend so the test frame's `cur` reflects the EOA caller.
func attachSend(ugnot int64) {
	if ugnot > 0 {
		coins := chain.NewCoins(chain.NewCoin(nativeDenom, ugnot))
		testing.SetOriginSend(coins)
		testing.SetOriginSpend(nil)
		testing.IssueCoins(realmAddr, coins)
	} else {
		testing.SetOriginSend(nil)
		testing.SetOriginSpend(nil)
	}
}

func coinBalance(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, nativeDenom)
}

func TestHappyPathMultiMilestoneAndVaultIsolation(cur realm, t *testing.T) {
	resetRealmState()

	// 1. Alice posts Bounty #1 with 10 GNOT split 30/50/20 across 3 milestones.
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(10_000_000)
	id1 := PostBounty(
		cross(cur),
		"Build On-Chain Indexer",
		"Deliver deterministic Gno event indexer with benchmarks.",
		"indexer,realm,go",
		"Spec & API:3000,Core Engine:5000,Benchmarks & Docs:2000",
		14,
		50_000,
		3,
	)
	urequire.Equal(t, uint64(1), id1)

	// 2. Alice also posts Bounty #2 with 4 GNOT to prove sub-realm vault isolation.
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(4_000_000)
	id2 := PostBounty(
		cross(cur),
		"Write GnoConnect Guide",
		"Concise walkthrough for wallet signing.",
		"docs,wallet",
		"Full Delivery",
		7,
		0,
		0,
	)
	urequire.Equal(t, uint64(2), id2)

	v1 := DeriveEscrowAddress(id1)
	v2 := DeriveEscrowAddress(id2)
	uassert.NotEqual(t, v1, v2, "each bounty must have a unique sub-realm vault address")
	uassert.Equal(t, int64(10_000_000), coinBalance(v1), "bounty 1 vault holds 10 GNOT")
	uassert.Equal(t, int64(4_000_000), coinBalance(v2), "bounty 2 vault holds 4 GNOT")

	// 3. Carol co-funds Bounty #1 by 2 GNOT directly via TopUpBounty (+2 GNOT -> 12 GNOT total).
	testing.SetRealm(testing.NewUserRealm(carol))
	attachSend(2_000_000)
	newTotal := TopUpBounty(cross(cur), id1)
	uassert.Equal(t, int64(12_000_000), newTotal)
	uassert.Equal(t, int64(12_000_000), coinBalance(v1))

	// 4. External DAO/bank sends 1 GNOT straight to DeriveEscrowAddress(id1), then calls SyncBountyVault.
	testing.IssueCoins(v1, chain.NewCoins(chain.NewCoin(nativeDenom, 1_000_000)))
	testing.SetRealm(testing.NewUserRealm(carol))
	attachSend(0)
	synced := SyncBountyVault(cross(cur), id1)
	uassert.Equal(t, int64(1_000_000), synced)
	uassert.Equal(t, int64(13_000_000), coinBalance(v1))

	// Verify dust-free payout math across 30% / 50% / 20% of 13 GNOT = 3.9 + 6.5 + 2.6 = 13.0 GNOT.
	ms := GetMilestones(id1)
	urequire.Equal(t, 3, len(ms))
	uassert.Equal(t, int64(13_000_000), ms[0].PayoutUgnot+ms[1].PayoutUgnot+ms[2].PayoutUgnot)

	// 5. Bob claims Bounty #1 (sponsor self-claim must abort).
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(0)
	uassert.AbortsWithMessage(t, cur, "sponsor cannot claim own bounty", func() {
		ClaimBounty(cross(cur), id1, "self claim attempt")
	})

	testing.SetRealm(testing.NewUserRealm(bob))
	attachSend(0)
	ClaimBounty(cross(cur), id1, "Shipping with full GnoVM test coverage.")

	// 6. Bob submits and Alice approves all 3 milestones sequentially.
	bobBefore := coinBalance(bob)
	for i := 0; i < 3; i++ {
		testing.SetRealm(testing.NewUserRealm(bob))
		attachSend(0)
		SubmitMilestone(cross(cur), id1, i, "https://github.com/reactrailgun/tavernboard/pull/1", "Delivered milestone cleanly")

		testing.SetRealm(testing.NewUserRealm(alice))
		attachSend(0)
		ApproveMilestone(cross(cur), id1, i, "Verified and accepted!")
	}

	// Verify exact payouts, vault #1 drained to 0, vault #2 untouched at 4 GNOT!
	uassert.Equal(t, bobBefore+13_000_000, coinBalance(bob), "builder received exact 13 GNOT")
	uassert.Equal(t, int64(0), coinBalance(v1), "bounty 1 escrow vault drained to 0")
	uassert.Equal(t, int64(4_000_000), coinBalance(v2), "bounty 2 escrow vault completely untouched")

	snap, ok := GetBounty(id1)
	urequire.True(t, ok)
	uassert.Equal(t, tavernkit.StatusCompleted.String(), snap.Status.String())

	// 7. Verify Bob's on-chain composable reputation & Craft Tier.
	rep := GetReputation(bob)
	// 1 completed (250) + 3 milestones (240) + 13 GNOT * 5 (65) = 555 XP -> Journeyman!
	uassert.Equal(t, int64(555), rep.XP)
	uassert.Equal(t, tavernkit.TierJourneyman.String(), rep.Tier.String())
	uassert.True(t, HasCraftTier(bob, tavernkit.TierJourneyman))
	uassert.False(t, HasCraftTier(bob, tavernkit.TierArtisan))

	// 8. Permissionless storage-deposit reclamation via ArchiveClosedBounty!
	testing.SetRealm(testing.NewUserRealm(janitor))
	attachSend(0)
	ArchiveClosedBounty(cross(cur), id1)
	snapAfter, _ := GetBounty(id1)
	uassert.True(t, snapAfter.Archived)
	uassert.Equal(t, tavernkit.StatusArchived.String(), snapAfter.Status.String())
	uassert.Equal(t, "", snapAfter.Summary, "heavy summary pruned to reclaim storage deposit")
}

func TestStakeBackedDisputeQuorumAndSlashing(cur realm, t *testing.T) {
	resetRealmState()

	// Alice posts 6 GNOT single-milestone quest with 0.1 GNOT reviewer stake and quorum 3.
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(6_000_000)
	id := PostBounty(
		cross(cur),
		"Audit Escrow Invariants",
		"Formal review of sub-realm banker boundaries.",
		"security,audit",
		"Audit Report",
		10,
		100_000,
		3,
	)

	testing.SetRealm(testing.NewUserRealm(bob))
	attachSend(0)
	ClaimBounty(cross(cur), id, "Will inspect all cross-realm paths.")
	SubmitMilestone(cross(cur), id, 0, "https://github.com/reactrailgun/tavernboard/blob/main/AUDIT.md", "Full report submitted.")

	// Alice requests revision; Bob disagrees and escalates to stake-backed quorum.
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(0)
	RequestRevision(cross(cur), id, 0, "Needs more coverage on sub-realms.")

	testing.SetRealm(testing.NewUserRealm(bob))
	attachSend(0)
	OpenDispute(cross(cur), id, 0, "Sub-realm analysis is covered in section 4 of the report.")

	// Sponsor/builder cannot vote on own dispute.
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(100_000)
	uassert.AbortsWithMessage(t, cur, "sponsor and builder cannot vote as reviewers on their own dispute", func() {
		StakeAndVoteDispute(cross(cur), id, 0, false, "trying to self-vote")
	})

	// Record reviewer starting balances.
	r1Before := coinBalance(rev1)
	r2Before := coinBalance(rev2)
	r3Before := coinBalance(rev3)
	bobBefore := coinBalance(bob)

	// Reviewer 1 stakes 100,000 ugnot and votes APPROVE builder.
	testing.SetRealm(testing.NewUserRealm(rev1))
	attachSend(100_000)
	resolved := StakeAndVoteDispute(cross(cur), id, 0, true, "Section 4 thoroughly covers sub-realm banker guards.")
	uassert.False(t, resolved)
	uassert.Equal(t, int64(100_000), coinBalance(DeriveStakeAddress(id)))

	// Reviewer 2 stakes 100,000 ugnot and votes REJECT builder (minority dissenter).
	testing.SetRealm(testing.NewUserRealm(rev2))
	attachSend(100_000)
	resolved = StakeAndVoteDispute(cross(cur), id, 0, false, "Not enough detail.")
	uassert.False(t, resolved)

	// Duplicate vote by Reviewer 1 must abort.
	testing.SetRealm(testing.NewUserRealm(rev1))
	attachSend(100_000)
	uassert.AbortsWithMessage(t, cur, "reviewer has already voted on this dispute", func() {
		StakeAndVoteDispute(cross(cur), id, 0, true, "double vote")
	})

	// Reviewer 3 stakes 100,000 ugnot and votes APPROVE builder -> 2-1 quorum reached & settles!
	testing.SetRealm(testing.NewUserRealm(rev3))
	attachSend(100_000)
	resolved = StakeAndVoteDispute(cross(cur), id, 0, true, "Deliverable meets all criteria.")
	uassert.True(t, resolved)

	// Verify economic settlement:
	// - Bob wins 6,000,000 ugnot from escrow/<id>.
	// - Rev2 (dissenter) slashed 50% (50,000 ugnot) -> gets 50,000 back.
	// - Rev1 & Rev3 (aligned) split the 50,000 slash pool (+25,000 each) -> get 125,000 each.
	// - Both escrow/<id> and stake/<id> vaults drain cleanly to 0 ugnot!
	uassert.Equal(t, bobBefore+6_000_000, coinBalance(bob), "builder paid on quorum win")
	uassert.Equal(t, r1Before+125_000, coinBalance(rev1), "aligned reviewer 1 got principal + 25k slash bonus")
	uassert.Equal(t, r2Before+50_000, coinBalance(rev2), "dissenting reviewer 2 slashed 50%")
	uassert.Equal(t, r3Before+125_000, coinBalance(rev3), "aligned reviewer 3 got principal + 25k slash bonus")
	uassert.Equal(t, int64(0), coinBalance(DeriveEscrowAddress(id)), "escrow vault empty")
	uassert.Equal(t, int64(0), coinBalance(DeriveStakeAddress(id)), "stake vault empty")

	// Verify reviewer reputation alignment vs slashing.
	p1 := GetProfile(rev1)
	p2 := GetProfile(rev2)
	uassert.Equal(t, int64(1), p1.ReviewsAligned)
	uassert.Equal(t, int64(0), p1.ReviewsSlashed)
	uassert.Equal(t, int64(1), p2.ReviewsSlashed)
	uassert.Equal(t, int64(0), p2.Score.ReliabilityBps)
}

func TestSecurityPaymentGuardBlocksCodeRealmSpoofing(cur realm, t *testing.T) {
	resetRealmState()

	// Regression test per Effective Gno § Verifying inbound Coin payments:
	// An intermediate code realm carrying OriginSend metadata MUST be rejected
	// by cur.Previous().IsUserCall() so it cannot mint fake escrow balances.
	attackerRealm := testing.NewCodeRealm("gno.land/r/attacker/wrapper")
	testing.SetRealm(attackerRealm)
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin(nativeDenom, 5_000_000)))

	uassert.AbortsWithMessage(t, cur, "direct user call (maketx call) required for coin transfers", func() {
		PostBounty(cross(cur), "Spoofed", "Fake funding", "sec", "Full", 7, 0, 0)
	})
}

func TestSecurityProofURLRejectsXSSScheme(cur realm, t *testing.T) {
	resetRealmState()

	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(1_000_000)
	id := PostBounty(cross(cur), "Build Widget", "Needs clean proof", "ui", "Full", 7, 0, 0)

	testing.SetRealm(testing.NewUserRealm(bob))
	attachSend(0)
	ClaimBounty(cross(cur), id, "On it")

	uassert.AbortsContains(t, cur, "proofURL rejected", func() {
		SubmitMilestone(cross(cur), id, 0, "javascript:alert(1)", "bad link")
	})
}

func TestCancelOpenAndReclaimExpiredBounty(cur realm, t *testing.T) {
	resetRealmState()

	aliceBefore := coinBalance(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(2_000_000)
	id := PostBounty(cross(cur), "Temporary Task", "Cancel before claim", "ops", "Full", 1, 0, 0)

	// Cancel unclaimed bounty immediately -> full 2 GNOT refunded.
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(0)
	refunded := CancelOrReclaimExpired(cross(cur), id)
	uassert.Equal(t, int64(2_000_000), refunded)
	uassert.Equal(t, aliceBefore+2_000_000, coinBalance(alice))
	uassert.Equal(t, int64(0), coinBalance(DeriveEscrowAddress(id)))

	// Claimed bounty cannot be cancelled before deadline, but CAN be reclaimed after expiry.
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(3_000_000)
	id2 := PostBounty(cross(cur), "Expiring Task", "Will expire", "ops", "Full", 1, 0, 0)

	testing.SetRealm(testing.NewUserRealm(bob))
	attachSend(0)
	ClaimBounty(cross(cur), id2, "Claimed but abandoned")

	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(0)
	uassert.AbortsWithMessage(t, cur, "claimed bounty cannot be cancelled before deadline", func() {
		CancelOrReclaimExpired(cross(cur), id2)
	})

	// Advance chain time past 1 day (17300 blocks * 5s > 86400s).
	testing.SkipHeights(17300)
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(0)
	refunded2 := CancelOrReclaimExpired(cross(cur), id2)
	uassert.Equal(t, int64(3_000_000), refunded2)
	uassert.Equal(t, int64(0), coinBalance(DeriveEscrowAddress(id2)))
}

func TestRenderSanitizationAndAllRoutes(cur realm, t *testing.T) {
	resetRealmState()

	// Post a bounty containing hostile Markdown/table/HTML injection characters.
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(5_000_000)
	id := PostBounty(
		cross(cur),
		"Fix | Table | [Evil](javascript:alert(1))",
		"# Fake Heading\n<script>alert(1)</script>\nDeliver clean fix.",
		"security,markdown",
		"Patch:10000",
		7,
		0,
		0,
	)

	// Home view renders cleanly: hostile markdown links & pipes are neutralized.
	home := Render("")
	uassert.True(t, strings.Contains(home, "TavernBoard"))
	uassert.True(t, strings.Contains(home, "5 GNOT"))
	uassert.False(t, strings.Contains(home, "](javascript:"), "javascript link must be neutralized")
	uassert.True(t, strings.Contains(home, `\[Evil\]`), "brackets must be escaped")
	uassert.True(t, strings.Contains(home, "&#124;"), "table pipes must be escaped")

	// Bounty detail view renders SVG escrow card, vault address, and txlink actions.
	detail := Render("bounty/1")
	uassert.True(t, strings.Contains(detail, "data:image/svg+xml;base64,"))
	uassert.True(t, strings.Contains(detail, DeriveEscrowAddress(id).String()))
	uassert.True(t, strings.Contains(detail, "$help&func=ClaimBounty"))
	uassert.False(t, strings.Contains(detail, "\n# Fake Heading"), "fake ATX heading must be escaped")
	uassert.False(t, strings.Contains(detail, "\n<script>"), "raw HTML block opener must be escaped")

	// Guild hall, builder crest, guide, and JSON query API all render cleanly.
	guild := Render("guild")
	uassert.True(t, strings.Contains(guild, "Guild Hall"))

	builderView := Render("builder/" + alice.String())
	uassert.True(t, strings.Contains(builderView, "data:image/svg+xml;base64,"))

	guide := Render("guide")
	uassert.True(t, strings.Contains(guide, "Sub-Realm Escrow"))

	rawJSON := GetBoardJSON(10)
	uassert.True(t, strings.Contains(rawJSON, `"totalBounties":1`))
	uassert.True(t, strings.Contains(rawJSON, DeriveEscrowAddress(id).String()))
}

func TestBuilderGracePeriodDisputeAndSponsorQuorumWin(cur realm, t *testing.T) {
	resetRealmState()

	aliceBefore := coinBalance(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	attachSend(4_000_000)
	id := PostBounty(cross(cur), "Build Benchmark", "Must pass gas target", "perf", "Full", 14, 100_000, 3)

	// Bob claims, then releases claim, then claims again.
	testing.SetRealm(testing.NewUserRealm(bob))
	attachSend(0)
	ClaimBounty(cross(cur), id, "First attempt")
	ReleaseClaim(cross(cur), id)
	ClaimBounty(cross(cur), id, "Committed attempt")
	SubmitMilestone(cross(cur), id, 0, "https://github.com/reactrailgun/tavernboard/pull/9", "Submitted draft")

	// Builder cannot dispute immediately while sponsor is inside 48h grace period.
	uassert.AbortsWithMessage(t, cur, "sponsor still within 48h review grace period", func() {
		OpenDispute(cross(cur), id, 0, "impatient")
	})

	// Advance chain past 48h (34600 blocks * 5s > 48h) -> builder can escalate!
	testing.SkipHeights(34600)
	testing.SetRealm(testing.NewUserRealm(bob))
	attachSend(0)
	OpenDispute(cross(cur), id, 0, "Sponsor unresponsive past 48h")

	// Quorum votes 2-1 in favor of SPONSOR (rejects incomplete deliverable).
	testing.SetRealm(testing.NewUserRealm(rev1))
	attachSend(100_000)
	StakeAndVoteDispute(cross(cur), id, 0, false, "Benchmarks do not pass")

	testing.SetRealm(testing.NewUserRealm(rev2))
	attachSend(100_000)
	StakeAndVoteDispute(cross(cur), id, 0, true, "Looks okay to me")

	testing.SetRealm(testing.NewUserRealm(rev3))
	attachSend(100_000)
	resolved := StakeAndVoteDispute(cross(cur), id, 0, false, "Missing gas metrics")
	uassert.True(t, resolved)

	// Escrow refunded to Alice; Bob incurs DisputesLost=1; vault drained to 0.
	uassert.Equal(t, aliceBefore+4_000_000, coinBalance(alice), "sponsor refunded on quorum win")
	uassert.Equal(t, int64(0), coinBalance(DeriveEscrowAddress(id)))
	uassert.Equal(t, int64(0), coinBalance(DeriveStakeAddress(id)))
	uassert.Equal(t, int64(1), GetProfile(bob).DisputesLost)
}
