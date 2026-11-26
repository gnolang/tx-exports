package tavernkit

import (
	"fmt"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestParseMilestoneSpecs(t *testing.T) {
	// Empty defaults to 100% single milestone.
	specs, err := ParseMilestoneSpecs("")
	uassert.NoError(t, err)
	uassert.Equal(t, 1, len(specs))
	uassert.Equal(t, "Full Delivery", specs[0].Title)
	uassert.Equal(t, int64(10000), specs[0].WeightBps)

	// Shorthand single milestone.
	specs, err = ParseMilestoneSpecs("Ship GRC20 Bridge")
	uassert.NoError(t, err)
	uassert.Equal(t, 1, len(specs))
	uassert.Equal(t, "Ship GRC20 Bridge", specs[0].Title)
	uassert.Equal(t, int64(10000), specs[0].WeightBps)

	// Multi-milestone weighted.
	specs, err = ParseMilestoneSpecs("Design Spec:2500, Core Realm:5000, Tests & Docs:2500")
	uassert.NoError(t, err)
	uassert.Equal(t, 3, len(specs))
	uassert.Equal(t, "Design Spec", specs[0].Title)
	uassert.Equal(t, int64(2500), specs[0].WeightBps)
	uassert.Equal(t, "Core Realm", specs[1].Title)
	uassert.Equal(t, int64(5000), specs[1].WeightBps)
	uassert.Equal(t, "Tests & Docs", specs[2].Title)
	uassert.Equal(t, int64(2500), specs[2].WeightBps)

	// Bad sum rejected.
	_, err = ParseMilestoneSpecs("A:3000,B:3000")
	uassert.Error(t, err)

	// Zero weight rejected.
	_, err = ParseMilestoneSpecs("A:0,B:10000")
	uassert.Error(t, err)

	// Too many milestones (> 8) rejected.
	_, err = ParseMilestoneSpecs("1:1000,2:1000,3:1000,4:1000,5:1000,6:1000,7:1000,8:1000,9:2000")
	uassert.Error(t, err)
}

func TestAllocatePayoutsDustFree(t *testing.T) {
	// 100 ugnot split 3333 / 3333 / 3334 -> 33 + 33 + 34 = 100 (zero dust lost!)
	payouts, err := AllocatePayouts(100, []int64{3333, 3333, 3334})
	uassert.NoError(t, err)
	uassert.Equal(t, 3, len(payouts))
	uassert.Equal(t, int64(33), payouts[0])
	uassert.Equal(t, int64(33), payouts[1])
	uassert.Equal(t, int64(34), payouts[2])
	uassert.Equal(t, int64(100), payouts[0]+payouts[1]+payouts[2])

	// Odd amount 1_000_007 across 3 milestones sums identically.
	payouts, err = AllocatePayouts(1000007, []int64{2500, 5000, 2500})
	uassert.NoError(t, err)
	uassert.Equal(t, int64(1000007), payouts[0]+payouts[1]+payouts[2])

	// Negative rejected.
	_, err = AllocatePayouts(-1, []int64{10000})
	uassert.Error(t, err)
}

func TestComputeReputationAndTiers(t *testing.T) {
	// Fresh builder -> Apprentice, 0 XP, 100% reliability.
	s0 := ComputeReputation(ReputationInput{})
	uassert.Equal(t, int64(0), s0.XP)
	uassert.Equal(t, TierApprentice.String(), s0.Tier.String())
	uassert.Equal(t, int64(10000), s0.ReliabilityBps)
	uassert.Equal(t, int64(250), s0.NextTierXP)

	// Active builder -> Journeyman (250 + 160 + 50 = 460 XP).
	s1 := ComputeReputation(ReputationInput{
		CompletedBounties:  1,
		ApprovedMilestones: 2,
		TotalEarnedUgnot:   10 * UgnotPerGnot,
	})
	uassert.Equal(t, int64(460), s1.XP)
	uassert.Equal(t, TierJourneyman.String(), s1.Tier.String())
	uassert.Equal(t, int64(750), s1.NextTierXP)

	// Slashing reduces XP and reliability, floored at 0.
	sSlash := ComputeReputation(ReputationInput{
		ReviewsAligned: 1,
		ReviewsSlashed: 3,
		DisputesLost:   1,
	})
	uassert.Equal(t, int64(0), sSlash.XP)
	uassert.Equal(t, TierApprentice.String(), sSlash.Tier.String())
	uassert.Equal(t, int64(2000), sSlash.ReliabilityBps) // 1 / 5 = 20%

	// Archmage ceiling.
	sMax := ComputeReputation(ReputationInput{
		CompletedBounties:  15,
		ApprovedMilestones: 30,
		TotalEarnedUgnot:   10000 * UgnotPerGnot, // capped at 500 GNOT bonus
		ReviewsAligned:     10,
	})
	uassert.Equal(t, TierArchmage.String(), sMax.Tier.String())
	uassert.Equal(t, int64(0), sMax.NextTierXP)
	uassert.Equal(t, int64(10000), sMax.ProgressBps)
}

func TestEvaluateQuorum(t *testing.T) {
	// Below quorum -> undecided.
	q1 := EvaluateQuorum(2, 0, 3)
	uassert.False(t, q1.Decided)

	// Tie at quorum (e.g. 2 vs 2 with minQuorum 3) -> undecided.
	qTie := EvaluateQuorum(2, 2, 3)
	uassert.False(t, qTie.Decided)

	// Strict majority builder wins (2 vs 1 with minQuorum 3).
	qWin := EvaluateQuorum(2, 1, 3)
	uassert.True(t, qWin.Decided)
	uassert.True(t, qWin.BuilderWins)

	// Strict majority sponsor wins (1 vs 2 with minQuorum 3).
	qReject := EvaluateQuorum(1, 2, 3)
	uassert.True(t, qReject.Decided)
	uassert.False(t, qReject.BuilderWins)
}

func TestFormatGNOT(t *testing.T) {
	uassert.Equal(t, "0 GNOT", FormatGNOT(0))
	uassert.Equal(t, "5 GNOT", FormatGNOT(5000000))
	uassert.Equal(t, "12.50 GNOT", FormatGNOT(12500000))
	uassert.Equal(t, "0.0025 GNOT", FormatGNOT(2500))
	uassert.Equal(t, "-1.25 GNOT", FormatGNOT(-1250000))
}

func TestRenderSVGSanitizesInput(t *testing.T) {
	score := ComputeReputation(ReputationInput{
		CompletedBounties:  4,
		ApprovedMilestones: 8,
		TotalEarnedUgnot:   25 * UgnotPerGnot,
	})
	crest := RenderGuildCrestSVG(`<script>alert(1)</script>`, score, 4, 25*UgnotPerGnot)
	uassert.True(t, strings.HasPrefix(crest, "![Guild Crest for "))
	uassert.True(t, strings.Contains(crest, "data:image/svg+xml;base64,"))
	uassert.False(t, strings.Contains(crest, "<script>"))

	escrow := RenderEscrowCardSVG("1", StatusInReview, 10*UgnotPerGnot, 4*UgnotPerGnot, 1, 3)
	uassert.True(t, strings.HasPrefix(escrow, "![Escrow Vault 1](data:image/svg+xml;base64,"))
}

func ExampleFormatGNOT() {
	fmt.Println(FormatGNOT(12500000))
	// Output:
	// 12.50 GNOT
}
