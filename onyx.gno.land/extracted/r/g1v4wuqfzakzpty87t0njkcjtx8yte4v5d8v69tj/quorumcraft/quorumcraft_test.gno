package quorumcraft

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	addrSponsor  = testutils.TestAddress("sponsor")
	addrReviewer = testutils.TestAddress("reviewer")
	addrBuilderA = testutils.TestAddress("buildera")
	addrBuilderB = testutils.TestAddress("builderb")
	addrBuilderC = testutils.TestAddress("builderc")
	addrSybil1   = testutils.TestAddress("sybil1")
	addrSybil2   = testutils.TestAddress("sybil2")
	addrWhale    = testutils.TestAddress("whale")
	addrOutsider = testutils.TestAddress("outsider")
)

func resetState() {
	rounds = nil
	totalEscrowed = 0
	totalReleased = 0
	totalRefunded = 0
}

// attachUgnot mirrors the SDK's pre-execution MsgCall coin transfer into the
// realm address and configures testing.SetOriginSend. Note that testing.SetRealm
// MUST be called directly in the test function frame (not inside a helper).
func attachUgnot(ugnotAmt int64) {
	realmAddr := chain.PackageAddress(realmPkgPath)
	if ugnotAmt > 0 {
		coins := chain.NewCoins(chain.NewCoin(ugnotDenom, ugnotAmt))
		testing.IssueCoins(realmAddr, coins)
		testing.SetOriginSend(coins)
	} else {
		testing.SetOriginSend(nil)
	}
}

func makeGrassrootsDonors(n int) []address {
	out := make([]address, n)
	for i := 0; i < n; i++ {
		out[i] = testutils.TestAddress("grassdonor" + string(rune('a'+i)))
	}
	return out
}

func TestCreateRoundAndFundMatchingPool(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(5_000_000)
	rid := CreateRound(cross(cur), "Onyx Public Goods #1", "Supporting Gno infra", int(ModePairwiseQF), 500_000, 5000, 100)
	uassert.Equal(t, 1, rid)

	r := GetRound(rid)
	uassert.Equal(t, int64(5_000_000), r.MatchingPool)
	uassert.Equal(t, ModePairwiseQF.String(), r.Mode.String())
	uassert.Equal(t, RoundOpen.String(), r.Status.String())

	// Top up matching pool from another sponsor/funder
	testing.SetRealm(testing.NewUserRealm(addrReviewer))
	attachUgnot(2_500_000)
	FundMatchingPool(cross(cur), rid)
	uassert.Equal(t, int64(7_500_000), r.MatchingPool)
	uassert.Equal(t, int64(7_500_000), GetProtocolStats().TotalEscrowed)
}

func TestCreateRoundValidationPanics(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(0)

	uassert.AbortsWithMessage(t, cur, "quorumcraft: invalid round name", func() {
		CreateRound(cross(cur), "", "desc", int(ModePairwiseQF), 500_000, 5000, 0)
	})
	uassert.AbortsWithMessage(t, cur, "quorumcraft: PairwiseQF requires positive penaltyCoeff", func() {
		CreateRound(cross(cur), "Bad", "desc", int(ModePairwiseQF), 0, 5000, 0)
	})
	uassert.AbortsWithMessage(t, cur, "quorumcraft: quorumBps must be between 1 and 10000", func() {
		CreateRound(cross(cur), "Bad", "desc", int(ModeStandardQF), 0, 15000, 0)
	})
}

func TestCoinTransferGuardsRejectNonEOAAndWrongDenom(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(1_000_000)
	rid := CreateRound(cross(cur), "Guard Round", "Test", int(ModePairwiseQF), 100_000, 5000, 0)

	// Zero send to FundMatchingPool must abort
	testing.SetRealm(testing.NewUserRealm(addrReviewer))
	attachUgnot(0)
	uassert.AbortsWithMessage(t, cur, "quorumcraft: must send positive ugnot amount", func() {
		FundMatchingPool(cross(cur), rid)
	})

	// Non-ugnot denomination must abort
	testing.SetRealm(testing.NewUserRealm(addrReviewer))
	testing.SetOriginSend(chain.NewCoins(chain.NewCoin("uatom", 100_000)))
	uassert.AbortsWithMessage(t, cur, "quorumcraft: only ugnot denomination accepted", func() {
		FundMatchingPool(cross(cur), rid)
	})

	// Non-EOA (code realm) coin send must abort
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/counter"))
	attachUgnot(100_000)
	uassert.AbortsWithMessage(t, cur, "quorumcraft: direct user call (maketx call) required for coin transfers", func() {
		FundMatchingPool(cross(cur), rid)
	})
}

func TestSubmitProposalMilestoneValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(1_000_000)
	rid := CreateRound(cross(cur), "Milestone Validation Round", "Test", int(ModePairwiseQF), 200_000, 5000, 0)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	attachUgnot(0)
	pid := SubmitProposal(
		cross(cur), rid,
		"Gno Indexer",
		"https://github.com/example/gno-indexer",
		"Fast deterministic indexer for Gno realms.",
		"Spec & Architecture:3000|Testnet MVP:4000|Audit & Docs:3000",
	)
	uassert.Equal(t, 1, pid)
	p := GetRound(rid).Proposals[0]
	uassert.Equal(t, 3, len(p.Milestones))
	uassert.Equal(t, int64(3000), p.Milestones[0].Bps)
	uassert.Equal(t, int64(4000), p.Milestones[1].Bps)

	// Invalid milestone sum (not 10000) must abort
	uassert.AbortsWithMessage(t, cur, "quorumcraft: milestone basis points must sum to 10000", func() {
		SubmitProposal(cross(cur), rid, "Bad Sum", "", "desc", "M1:5000|M2:4000")
	})
	// Only 1 milestone must abort
	uassert.AbortsWithMessage(t, cur, "quorumcraft: proposal must define 2 to 4 milestones", func() {
		SubmitProposal(cross(cur), rid, "Too Few", "", "desc", "OnlyOne:10000")
	})
}

func TestContributeRejectsSelfDonationAndAggregatesRepeats(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(1_000_000)
	rid := CreateRound(cross(cur), "Self-Deal Guard", "Test", int(ModePairwiseQF), 200_000, 5000, 0)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	attachUgnot(0)
	pid := SubmitProposal(cross(cur), rid, "Tool", "", "Summary", "M1:5000|M2:5000")

	// Recipient cannot donate to own proposal
	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	attachUgnot(100_000)
	uassert.AbortsWithMessage(t, cur, "quorumcraft: proposal recipient cannot self-contribute", func() {
		Contribute(cross(cur), rid, pid)
	})

	// Repeat contributions from same donor merge into single donor record
	testing.SetRealm(testing.NewUserRealm(addrWhale))
	attachUgnot(200_000)
	Contribute(cross(cur), rid, pid)
	attachUgnot(300_000)
	Contribute(cross(cur), rid, pid)

	p := GetRound(rid).Proposals[0]
	uassert.Equal(t, int64(500_000), p.DirectTotal)
	uassert.Equal(t, 1, p.DonorContribs.Size())
	uassert.Equal(t, int64(500_000), p.DonorContribs.Get(addrWhale.String()).(int64))
}

func TestSybilCollusionNeutralizationEndToEnd(cur realm, t *testing.T) {
	resetState()
	const matchingPool int64 = 10_000_000
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(matchingPool)
	rid := CreateRound(cross(cur), "Anti-Collusion Arena", "Pairwise vs Sybil ring", int(ModePairwiseQF), 200_000, 5000, 0)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	attachUgnot(0)
	pCollude1 := SubmitProposal(cross(cur), rid, "Sybil Target Alpha", "https://github.com/a/alpha", "Ring target 1", "M1:5000|M2:5000")

	testing.SetRealm(testing.NewUserRealm(addrBuilderB))
	pCollude2 := SubmitProposal(cross(cur), rid, "Sybil Target Beta", "https://github.com/b/beta", "Ring target 2", "M1:5000|M2:5000")

	testing.SetRealm(testing.NewUserRealm(addrBuilderC))
	pGrassroots := SubmitProposal(cross(cur), rid, "Open Gno SDK", "https://github.com/c/sdk", "Community-backed tool", "M1:3000|M2:4000|M3:3000")

	// 2 sybil wallets co-donate 500k each to BOTH collusion targets
	for _, pid := range []int{pCollude1, pCollude2} {
		testing.SetRealm(testing.NewUserRealm(addrSybil1))
		attachUgnot(500_000)
		Contribute(cross(cur), rid, pid)

		testing.SetRealm(testing.NewUserRealm(addrSybil2))
		attachUgnot(500_000)
		Contribute(cross(cur), rid, pid)
	}

	// 8 organic community donors each give 100k to the Grassroots SDK
	donors := makeGrassrootsDonors(8)
	for _, d := range donors {
		testing.SetRealm(testing.NewUserRealm(d))
		attachUgnot(100_000)
		Contribute(cross(cur), rid, pGrassroots)
	}

	// Preview before finalization
	stdPrev, pwPrev := PreviewRoundMatching(rid)
	uassert.True(t, pwPrev[0] < stdPrev[0])
	uassert.True(t, pwPrev[1] < stdPrev[1])
	uassert.True(t, pwPrev[2] > stdPrev[2])

	// Finalize round as sponsor
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(0)
	FinalizeRound(cross(cur), rid)

	r := GetRound(rid)
	uassert.Equal(t, RoundFinalized.String(), r.Status.String())
	// Exact conservation: matched grants sum strictly to matchingPool
	sumMatched := r.Proposals[0].MatchedGrant + r.Proposals[1].MatchedGrant + r.Proposals[2].MatchedGrant
	uassert.Equal(t, matchingPool, sumMatched)
	// PairwiseQF penalized collusion targets relative to StandardQF and rewarded grassroots
	uassert.True(t, r.Proposals[0].MatchedGrant < r.Proposals[0].StandardQFMatched)
	uassert.True(t, r.Proposals[2].MatchedGrant > r.Proposals[2].StandardQFMatched)
}

func TestWhaleVsGrassrootsStandardQFMode(cur realm, t *testing.T) {
	resetState()
	const pool int64 = 6_000_000
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(pool)
	rid := CreateRound(cross(cur), "Standard CLR Round", "Whale vs crowd", int(ModeStandardQF), 0, 5000, 0)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	attachUgnot(0)
	pWhale := SubmitProposal(cross(cur), rid, "Whale Project", "", "Single whale", "M1:5000|M2:5000")

	testing.SetRealm(testing.NewUserRealm(addrBuilderB))
	pCrowd := SubmitProposal(cross(cur), rid, "Crowd Project", "", "Grassroots crowd", "M1:5000|M2:5000")

	// 1 whale gives 1,000,000
	testing.SetRealm(testing.NewUserRealm(addrWhale))
	attachUgnot(1_000_000)
	Contribute(cross(cur), rid, pWhale)

	// 10 crowd donors give 100,000 each (same total direct: 1,000,000)
	for _, d := range makeGrassrootsDonors(10) {
		testing.SetRealm(testing.NewUserRealm(d))
		attachUgnot(100_000)
		Contribute(cross(cur), rid, pCrowd)
	}

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(0)
	FinalizeRound(cross(cur), rid)

	r := GetRound(rid)
	uassert.Equal(t, int64(0), r.Proposals[0].MatchedGrant)
	uassert.Equal(t, pool, r.Proposals[1].MatchedGrant)
}

func TestMilestoneProofQuorumAttestationAndRealBankerPayout(cur realm, t *testing.T) {
	resetState()
	const pool int64 = 4_000_000
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(pool)
	rid := CreateRound(cross(cur), "Escrow Lifecycle", "Full tranche payout", int(ModePairwiseQF), 500_000, 5000, 0)

	// Add a reviewer (Sponsor + Reviewer + 2 Donors = 4 eligible -> 50% quorum = 2)
	attachUgnot(0)
	AddReviewer(cross(cur), rid, addrReviewer)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	pid := SubmitProposal(
		cross(cur), rid,
		"Gno Escrow Engine",
		"https://github.com/quorumcraft/engine",
		"Deterministic milestone payouts.",
		"M1 Spec:3333|M2 Beta:3333|M3 Launch:3334",
	)

	donors := makeGrassrootsDonors(2)
	testing.SetRealm(testing.NewUserRealm(donors[0]))
	attachUgnot(500_000)
	Contribute(cross(cur), rid, pid)

	testing.SetRealm(testing.NewUserRealm(donors[1]))
	attachUgnot(500_000)
	Contribute(cross(cur), rid, pid)

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(0)
	FinalizeRound(cross(cur), rid)

	r := GetRound(rid)
	p := r.Proposals[0]
	// Total grant = 1,000,000 direct + 4,000,000 matched = 5,000,000 ugnot
	uassert.Equal(t, int64(5_000_000), p.TotalGrant())
	uassert.Equal(t, 4, EligibleAttestorCount(r, p))
	uassert.Equal(t, 2, RequiredQuorum(r, p))

	roBank := banker.NewReadonlyBanker()
	balBefore := roBank.GetCoin(addrBuilderA, ugnotDenom)

	// Deliver and release ALL 3 tranches, verifying zero-dust conservation!
	var sumPaid int64
	for mIdx := 0; mIdx < 3; mIdx++ {
		testing.SetRealm(testing.NewUserRealm(addrBuilderA))
		attachUgnot(0)
		SubmitMilestoneProof(cross(cur), rid, pid, mIdx, "https://github.com/quorumcraft/engine/releases/m"+string(rune('1'+mIdx)), "sha256:deadbeef")

		// 1 approval is not enough (needs 2)
		testing.SetRealm(testing.NewUserRealm(addrReviewer))
		AttestMilestone(cross(cur), rid, pid, mIdx)

		testing.SetRealm(testing.NewUserRealm(addrOutsider))
		uassert.AbortsWithMessage(t, cur, "quorumcraft: milestone has not reached attestation quorum", func() {
			ReleaseMilestone(cross(cur), rid, pid, mIdx)
		})

		// 2nd approval from a direct contributor reaches quorum!
		testing.SetRealm(testing.NewUserRealm(donors[0]))
		AttestMilestone(cross(cur), rid, pid, mIdx)

		// Permissionless release crank works from any caller
		testing.SetRealm(testing.NewUserRealm(addrOutsider))
		paid := ReleaseMilestone(cross(cur), rid, pid, mIdx)
		sumPaid += paid
		uassert.Equal(t, MilestoneReleased.String(), p.Milestones[mIdx].Status.String())
	}

	balAfter := roBank.GetCoin(addrBuilderA, ugnotDenom)
	uassert.Equal(t, int64(5_000_000), sumPaid)
	uassert.Equal(t, int64(5_000_000), balAfter-balBefore)
	uassert.Equal(t, int64(0), p.RemainingEscrow())
	uassert.Equal(t, int64(0), GetProtocolStats().TotalEscrowed)
	uassert.Equal(t, int64(5_000_000), GetProtocolStats().TotalReleased)
}

func TestDisputeBlocksReleaseAndSlashesToSponsor(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(2_000_000)
	rid := CreateRound(cross(cur), "Dispute Round", "Slashing check", int(ModePairwiseQF), 500_000, 5000, 0)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	attachUgnot(0)
	pid := SubmitProposal(cross(cur), rid, "Flaky Project", "", "Summary", "M1:4000|M2:6000")

	donors := makeGrassrootsDonors(2)
	testing.SetRealm(testing.NewUserRealm(donors[0]))
	attachUgnot(500_000)
	Contribute(cross(cur), rid, pid)

	testing.SetRealm(testing.NewUserRealm(donors[1]))
	attachUgnot(500_000)
	Contribute(cross(cur), rid, pid)

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(0)
	FinalizeRound(cross(cur), rid)

	// Builder submits M0 proof
	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	SubmitMilestoneProof(cross(cur), rid, pid, 0, "https://example.com/fake", "0x000")

	// Donor disputes M0
	testing.SetRealm(testing.NewUserRealm(donors[0]))
	DisputeMilestone(cross(cur), rid, pid, 0, "Deliverable repo is empty")

	// Attesting or releasing disputed milestone must fail
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	uassert.AbortsWithMessage(t, cur, "quorumcraft: milestone is not awaiting attestation", func() {
		AttestMilestone(cross(cur), rid, pid, 0)
	})
	uassert.AbortsWithMessage(t, cur, "quorumcraft: milestone is not eligible for release", func() {
		ReleaseMilestone(cross(cur), rid, pid, 0)
	})

	// Non-sponsor cannot resolve dispute
	testing.SetRealm(testing.NewUserRealm(donors[0]))
	uassert.AbortsWithMessage(t, cur, "quorumcraft: only round sponsor can resolve disputes", func() {
		ResolveDispute(cross(cur), rid, pid, 0, false)
	})

	// Sponsor resolves dispute by refunding/slashing tranche (40% of 3,000,000 = 1,200,000)
	roBank := banker.NewReadonlyBanker()
	sponsorBalBefore := roBank.GetCoin(addrSponsor, ugnotDenom)
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	slashed := ResolveDispute(cross(cur), rid, pid, 0, false)
	sponsorBalAfter := roBank.GetCoin(addrSponsor, ugnotDenom)

	uassert.Equal(t, int64(1_200_000), slashed)
	uassert.Equal(t, int64(1_200_000), sponsorBalAfter-sponsorBalBefore)
	uassert.Equal(t, MilestoneRefunded.String(), GetRound(rid).Proposals[0].Milestones[0].Status.String())
	uassert.Equal(t, int64(1_200_000), GetProtocolStats().TotalRefunded)
}

func TestDisputeResolvedInFavorOfBuilder(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(1_000_000)
	rid := CreateRound(cross(cur), "Override Dispute", "Test", int(ModeStandardQF), 0, 5000, 0)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	attachUgnot(0)
	pid := SubmitProposal(cross(cur), rid, "Solid Work", "", "Summary", "M1:5000|M2:5000")

	donors := makeGrassrootsDonors(2)
	testing.SetRealm(testing.NewUserRealm(donors[0]))
	attachUgnot(500_000)
	Contribute(cross(cur), rid, pid)

	testing.SetRealm(testing.NewUserRealm(donors[1]))
	attachUgnot(500_000)
	Contribute(cross(cur), rid, pid)

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(0)
	FinalizeRound(cross(cur), rid)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	SubmitMilestoneProof(cross(cur), rid, pid, 0, "https://github.com/solid/v1", "abc999")

	testing.SetRealm(testing.NewUserRealm(donors[1]))
	DisputeMilestone(cross(cur), rid, pid, 0, "False alarm dispute")

	roBank := banker.NewReadonlyBanker()
	balBefore := roBank.GetCoin(addrBuilderA, ugnotDenom)
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	released := ResolveDispute(cross(cur), rid, pid, 0, true)
	balAfter := roBank.GetCoin(addrBuilderA, ugnotDenom)

	uassert.Equal(t, int64(1_000_000), released)
	uassert.Equal(t, int64(1_000_000), balAfter-balBefore)
	uassert.Equal(t, MilestoneReleased.String(), GetRound(rid).Proposals[0].Milestones[0].Status.String())
}

func TestAccessControlGuards(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(1_000_000)
	rid := CreateRound(cross(cur), "ACL Round", "Test", int(ModePairwiseQF), 100_000, 5000, 100)

	// Non-sponsor cannot add reviewer
	testing.SetRealm(testing.NewUserRealm(addrOutsider))
	attachUgnot(0)
	uassert.AbortsWithMessage(t, cur, "quorumcraft: only round sponsor can add reviewers", func() {
		AddReviewer(cross(cur), rid, addrReviewer)
	})

	// Non-sponsor cannot finalize early before EndHeight
	uassert.AbortsWithMessage(t, cur, "quorumcraft: only sponsor can finalize before round end height", func() {
		FinalizeRound(cross(cur), rid)
	})

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	pid := SubmitProposal(cross(cur), rid, "Build", "", "Summary", "M1:5000|M2:5000")

	donors := makeGrassrootsDonors(1)
	testing.SetRealm(testing.NewUserRealm(donors[0]))
	attachUgnot(500_000)
	Contribute(cross(cur), rid, pid)

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(0)
	FinalizeRound(cross(cur), rid)

	// Non-recipient cannot submit proof
	testing.SetRealm(testing.NewUserRealm(addrOutsider))
	uassert.AbortsWithMessage(t, cur, "quorumcraft: only proposal recipient can submit milestone proof", func() {
		SubmitMilestoneProof(cross(cur), rid, pid, 0, "https://example.com", "abc")
	})

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	SubmitMilestoneProof(cross(cur), rid, pid, 0, "https://example.com", "abc")

	// Recipient cannot self-attest
	uassert.AbortsWithMessage(t, cur, "quorumcraft: caller is not an eligible attestor for this proposal", func() {
		AttestMilestone(cross(cur), rid, pid, 0)
	})

	// Unrelated outsider cannot attest
	testing.SetRealm(testing.NewUserRealm(addrOutsider))
	uassert.AbortsWithMessage(t, cur, "quorumcraft: caller is not an eligible attestor for this proposal", func() {
		AttestMilestone(cross(cur), rid, pid, 0)
	})

	// Duplicate attestation aborts
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	AttestMilestone(cross(cur), rid, pid, 0)
	uassert.AbortsWithMessage(t, cur, "quorumcraft: caller has already attested this milestone", func() {
		AttestMilestone(cross(cur), rid, pid, 0)
	})
}

func TestPermissionlessFinalizeAfterEndHeight(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(1_000_000)
	rid := CreateRound(cross(cur), "Timed Round", "Auto-close", int(ModePairwiseQF), 100_000, 5000, 10)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	attachUgnot(0)
	pid := SubmitProposal(cross(cur), rid, "Timed Build", "", "Summary", "M1:5000|M2:5000")

	donors := makeGrassrootsDonors(2)
	testing.SetRealm(testing.NewUserRealm(donors[0]))
	attachUgnot(100_000)
	Contribute(cross(cur), rid, pid)

	testing.SetRealm(testing.NewUserRealm(donors[1]))
	attachUgnot(100_000)
	Contribute(cross(cur), rid, pid)

	// Advance chain height past EndHeight -> outsider can now finalize!
	testing.SkipHeights(12)
	testing.SetRealm(testing.NewUserRealm(addrOutsider))
	attachUgnot(0)
	FinalizeRound(cross(cur), rid)
	uassert.Equal(t, RoundFinalized.String(), GetRound(rid).Status.String())
	uassert.Equal(t, int64(1_000_000), GetRound(rid).Proposals[0].MatchedGrant)
}

func TestFinalizeEmptyRoundRefundsSponsor(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(3_000_000)
	rid := CreateRound(cross(cur), "Empty Round", "No donors", int(ModePairwiseQF), 100_000, 5000, 0)

	roBank := banker.NewReadonlyBanker()
	balBefore := roBank.GetCoin(addrSponsor, ugnotDenom)
	attachUgnot(0)
	FinalizeRound(cross(cur), rid)
	balAfter := roBank.GetCoin(addrSponsor, ugnotDenom)

	uassert.Equal(t, int64(3_000_000), balAfter-balBefore)
	uassert.Equal(t, int64(0), GetProtocolStats().TotalEscrowed)
	uassert.Equal(t, int64(3_000_000), GetProtocolStats().TotalRefunded)
}

func TestFinalizedRoundBlocksNewContributionsAndProposals(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(1_000_000)
	rid := CreateRound(cross(cur), "Closed Round", "Test", int(ModeStandardQF), 0, 5000, 0)
	attachUgnot(0)
	FinalizeRound(cross(cur), rid)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	uassert.AbortsWithMessage(t, cur, "quorumcraft: round is already finalized", func() {
		SubmitProposal(cross(cur), rid, "Late", "", "Summary", "M1:5000|M2:5000")
	})

	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(500_000)
	uassert.AbortsWithMessage(t, cur, "quorumcraft: round is already finalized", func() {
		FundMatchingPool(cross(cur), rid)
	})
}

func TestMultiRoundIsolationAndProtocolStats(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(2_000_000)
	r1 := CreateRound(cross(cur), "Round Alpha", "First", int(ModePairwiseQF), 250_000, 5000, 0)
	attachUgnot(3_000_000)
	r2 := CreateRound(cross(cur), "Round Beta", "Second", int(ModeStandardQF), 0, 6667, 0)

	uassert.Equal(t, 1, r1)
	uassert.Equal(t, 2, r2)
	stats := GetProtocolStats()
	uassert.Equal(t, 2, stats.RoundCount)
	uassert.Equal(t, 2, stats.OpenRounds)
	uassert.Equal(t, int64(5_000_000), stats.TotalEscrowed)

	// Finalize empty Round 1 -> refunds 2M, leaves Round 2 open with 3M
	attachUgnot(0)
	FinalizeRound(cross(cur), r1)
	stats = GetProtocolStats()
	uassert.Equal(t, 1, stats.OpenRounds)
	uassert.Equal(t, int64(3_000_000), stats.TotalEscrowed)
	uassert.Equal(t, int64(2_000_000), stats.TotalRefunded)
}

func TestRenderAllRoutesAndNativeSVG(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(5_000_000)
	rid := CreateRound(cross(cur), "Gnome Tavern Public Goods", "Funding core Gno realms", int(ModePairwiseQF), 300_000, 5000, 0)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	attachUgnot(0)
	pid := SubmitProposal(
		cross(cur), rid,
		"GnoDB Explorer",
		"https://github.com/example/gnodb",
		"Real-time state tree inspector for Gno.land.",
		"Spec:3000|Testnet:4000|Mainnet:3000",
	)
	donors := makeGrassrootsDonors(3)
	for _, d := range donors {
		testing.SetRealm(testing.NewUserRealm(d))
		attachUgnot(250_000)
		Contribute(cross(cur), rid, pid)
	}
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(0)
	FinalizeRound(cross(cur), rid)

	// 1. Home route renders KPIs, rounds table, and embedded data:image/svg+xml chart
	home := Render("")
	uassert.True(t, strings.Contains(home, "# QuorumCraft"))
	uassert.True(t, strings.Contains(home, "Gnome Tavern Public Goods"))
	uassert.True(t, strings.Contains(home, "data:image/svg+xml;base64,"))

	// 2. Round detail route renders Pairwise vs Standard comparison & Nakamoto score
	roundPage := Render("round/1")
	uassert.True(t, strings.Contains(roundPage, "Nakamoto Coefficient"))
	uassert.True(t, strings.Contains(roundPage, "Pairwise-QF vs Standard-QF"))
	uassert.True(t, strings.Contains(roundPage, "GnoDB Explorer"))
	uassert.True(t, strings.Contains(roundPage, "data:image/svg+xml;base64,"))

	// 3. Proposal detail route renders milestone table, escrow SVG bar, and gnokey snippets
	propPage := Render("proposal/1/1")
	uassert.True(t, strings.Contains(propPage, "Milestone Tranches"))
	uassert.True(t, strings.Contains(propPage, "gnokey maketx call"))
	uassert.True(t, strings.Contains(propPage, "data:image/svg+xml;base64,"))

	// 4. Docs route
	docsPage := Render("docs")
	uassert.True(t, strings.Contains(docsPage, "Pairwise-Bounded Anti-Collusion"))

	// 5. Raw SVG markup verification (<svg ... </svg> + valid elements)
	chartSVG := RenderRoundChartSVG(rid)
	uassert.True(t, strings.HasPrefix(chartSVG, "<svg "))
	uassert.True(t, strings.Contains(chartSVG, "GnoDB Explorer"))
	uassert.True(t, strings.HasSuffix(chartSVG, "</svg>"))

	escrowSVG := RenderEscrowSVG(rid, pid)
	uassert.True(t, strings.HasPrefix(escrowSVG, "<svg "))
	uassert.True(t, strings.Contains(escrowSVG, "M1 (30%)"))
	uassert.True(t, strings.HasSuffix(escrowSVG, "</svg>"))

	// 6. Unknown route returns clean 404 page
	notFound := Render("does/not/exist")
	uassert.True(t, strings.Contains(notFound, "Page Not Found"))
}

func TestRenderSanitizesMarkdownInjection(cur realm, t *testing.T) {
	resetState()
	testing.SetRealm(testing.NewUserRealm(addrSponsor))
	attachUgnot(1_000_000)
	rid := CreateRound(cross(cur), "Safe | Round #1", "Desc", int(ModePairwiseQF), 100_000, 5000, 0)

	testing.SetRealm(testing.NewUserRealm(addrBuilderA))
	attachUgnot(0)
	SubmitProposal(
		cross(cur), rid,
		"Evil | Title [link](javascript:alert(1))",
		"javascript:alert(1)",
		"# Injected Heading\n<script>alert(1)</script>",
		"M1:5000|M2:5000",
	)

	propPage := Render("proposal/1/1")
	uassert.False(t, strings.Contains(propPage, "](javascript:alert(1))"))
	uassert.True(t, strings.Contains(propPage, "\\<script"))
}
