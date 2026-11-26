package tavernkit

import (
	"errors"
	"strconv"
	"strings"
)

// ParseMilestoneSpecs parses a comma-separated milestone specification string.
//
// Supported formats:
//   - Single milestone shorthand: "Full Delivery" -> [{Title: "Full Delivery", WeightBps: 10000}]
//   - Multi-milestone weighted:   "Spec:3000,Implementation:5000,Tests & Docs:2000"
//   - Empty string defaults to a single 100% milestone ("Full Delivery").
//
// Weights must be strictly positive and sum to exactly 10000 basis points (100%).
func ParseMilestoneSpecs(spec string) ([]MilestoneSpec, error) {
	trimmed := strings.TrimSpace(spec)
	if trimmed == "" {
		return []MilestoneSpec{{Title: "Full Delivery", WeightBps: BasisPointsTotal}}, nil
	}

	// Single shorthand without ":" or "," -> 100% single milestone.
	if !strings.Contains(trimmed, ",") && !strings.Contains(trimmed, ":") {
		if len(trimmed) > 80 {
			return nil, errors.New("milestone title exceeds 80 bytes")
		}
		return []MilestoneSpec{{Title: trimmed, WeightBps: BasisPointsTotal}}, nil
	}

	parts := strings.Split(trimmed, ",")
	if len(parts) > MaxMilestones {
		return nil, errors.New("too many milestones: max 8")
	}

	specs := make([]MilestoneSpec, 0, len(parts))
	var sumBps int64

	for _, raw := range parts {
		entry := strings.TrimSpace(raw)
		if entry == "" {
			return nil, errors.New("empty milestone entry")
		}
		sep := strings.LastIndex(entry, ":")
		if sep <= 0 || sep == len(entry)-1 {
			return nil, errors.New("milestone must use 'Title:WeightBps' format")
		}
		title := strings.TrimSpace(entry[:sep])
		weightStr := strings.TrimSpace(entry[sep+1:])
		if title == "" {
			return nil, errors.New("milestone title cannot be empty")
		}
		if len(title) > 80 {
			return nil, errors.New("milestone title exceeds 80 bytes")
		}
		w, err := strconv.ParseInt(weightStr, 10, 64)
		if err != nil || w <= 0 || w > BasisPointsTotal {
			return nil, errors.New("milestone weight must be an integer in 1..10000")
		}
		sumBps += w
		specs = append(specs, MilestoneSpec{
			Title:     title,
			WeightBps: w,
		})
	}

	if sumBps != BasisPointsTotal {
		return nil, errors.New("milestone weights must sum to exactly 10000 basis points")
	}
	return specs, nil
}

// AllocatePayouts splits totalAmount across weightsBps using exact integer math.
// Any rounding dust is assigned to the final milestone so sum(result) == totalAmount.
func AllocatePayouts(totalAmount int64, weightsBps []int64) ([]int64, error) {
	if totalAmount < 0 {
		return nil, errors.New("totalAmount cannot be negative")
	}
	if len(weightsBps) == 0 || len(weightsBps) > MaxMilestones {
		return nil, errors.New("invalid milestone count")
	}

	var sumBps int64
	for _, w := range weightsBps {
		if w <= 0 {
			return nil, errors.New("milestone weight must be positive")
		}
		sumBps += w
	}
	if sumBps != BasisPointsTotal {
		return nil, errors.New("milestone weights must sum to 10000 bps")
	}

	payouts := make([]int64, len(weightsBps))
	var allocated int64
	for i, w := range weightsBps {
		if i == len(weightsBps)-1 {
			payouts[i] = totalAmount - allocated
		} else {
			share := (totalAmount * w) / BasisPointsTotal
			payouts[i] = share
			allocated += share
		}
	}
	return payouts, nil
}

// ComputeReputation deterministically computes XP, CraftTier, and ReliabilityBps
// from on-chain activity counters using pure integer arithmetic.
func ComputeReputation(in ReputationInput) ReputationScore {
	gnotEarned := in.TotalEarnedUgnot / UgnotPerGnot
	if gnotEarned < 0 {
		gnotEarned = 0
	}
	// Cap earnings XP bonus at 500 GNOT (2500 XP) so whales cannot buy Archmage
	// without actually delivering bounties and aligned reviews.
	if gnotEarned > 500 {
		gnotEarned = 500
	}

	xp := in.CompletedBounties*250 +
		in.ApprovedMilestones*80 +
		gnotEarned*5 +
		in.ReviewsAligned*60 +
		in.DisputesWon*100 -
		in.ReviewsSlashed*120 -
		in.DisputesLost*150

	if xp < 0 {
		xp = 0
	}

	tier := TierForXP(xp)
	nextXP := nextTierThreshold(tier)
	var progressBps int64 = BasisPointsTotal
	if nextXP > 0 {
		floorXP := tier.MinXP()
		span := nextXP - floorXP
		if span > 0 {
			progressBps = ((xp - floorXP) * BasisPointsTotal) / span
			if progressBps < 0 {
				progressBps = 0
			}
			if progressBps > BasisPointsTotal {
				progressBps = BasisPointsTotal
			}
		}
	}

	positive := in.ApprovedMilestones + in.ReviewsAligned + in.DisputesWon
	negative := in.ReviewsSlashed + in.DisputesLost
	totalOutcomes := positive + negative
	var reliabilityBps int64 = BasisPointsTotal
	if totalOutcomes > 0 {
		reliabilityBps = (positive * BasisPointsTotal) / totalOutcomes
	}

	return ReputationScore{
		XP:             xp,
		Tier:           tier,
		ReliabilityBps: reliabilityBps,
		NextTierXP:     nextXP,
		ProgressBps:    progressBps,
	}
}

// TierForXP returns the CraftTier corresponding to an XP score.
func TierForXP(xp int64) CraftTier {
	switch {
	case xp >= TierArchmage.MinXP():
		return TierArchmage
	case xp >= TierMaster.MinXP():
		return TierMaster
	case xp >= TierArtisan.MinXP():
		return TierArtisan
	case xp >= TierJourneyman.MinXP():
		return TierJourneyman
	default:
		return TierApprentice
	}
}

func nextTierThreshold(t CraftTier) int64 {
	switch t {
	case TierApprentice:
		return TierJourneyman.MinXP()
	case TierJourneyman:
		return TierArtisan.MinXP()
	case TierArtisan:
		return TierMaster.MinXP()
	case TierMaster:
		return TierArchmage.MinXP()
	default:
		return 0
	}
}

// EvaluateQuorum checks whether reviewer votes have reached a decisive outcome.
// Ties are not decisive; an extra vote is required to break a tie so disputes
// always resolve by strict majority once minQuorum is met.
func EvaluateQuorum(approveVotes, rejectVotes, minQuorum int) QuorumTally {
	if minQuorum < 1 {
		minQuorum = 1
	}
	total := approveVotes + rejectVotes
	decided := total >= minQuorum && approveVotes != rejectVotes
	return QuorumTally{
		ApproveVotes: approveVotes,
		RejectVotes:  rejectVotes,
		TotalVotes:   total,
		MinQuorum:    minQuorum,
		Decided:      decided,
		BuilderWins:  decided && approveVotes > rejectVotes,
	}
}

// FormatGNOT formats an amount in ugnot as a clean human-readable GNOT string
// without floating-point arithmetic.
func FormatGNOT(ugnot int64) string {
	if ugnot == 0 {
		return "0 GNOT"
	}
	sign := ""
	if ugnot < 0 {
		sign = "-"
		ugnot = -ugnot
	}
	whole := ugnot / UgnotPerGnot
	frac := ugnot % UgnotPerGnot
	if frac == 0 {
		return sign + strconv.FormatInt(whole, 10) + " GNOT"
	}
	fracStr := strconv.FormatInt(frac, 10)
	// Pad left to 6 digits.
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	// Trim trailing zeroes while keeping at least 2 decimal places for readability.
	for len(fracStr) > 2 && fracStr[len(fracStr)-1] == '0' {
		fracStr = fracStr[:len(fracStr)-1]
	}
	return sign + strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

// FormatBpsPercent formats basis points (e.g. 9550) as "95.5%".
func FormatBpsPercent(bps int64) string {
	if bps <= 0 {
		return "0%"
	}
	whole := bps / 100
	tenth := (bps % 100) / 10
	if tenth == 0 {
		return strconv.FormatInt(whole, 10) + "%"
	}
	return strconv.FormatInt(whole, 10) + "." + strconv.FormatInt(tenth, 10) + "%"
}

// ShortAddr returns a compact representation of a bech32 address (e.g. g1abcd...wxyz).
func ShortAddr(addr address) string {
	s := string(addr)
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "..." + s[len(s)-4:]
}
