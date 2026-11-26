// Package escrowmath provides pure, deterministic milestone split math,
// quorum validation, Proof-of-Contribution XP scoring, and formatting helpers
// for OathLedger on Gno.land.
package escrowmath

import (
	"errors"
	"strconv"
	"strings"
)

const (
	BpsDenominator = int64(10000)
	MaxMilestones  = 10
	MaxReviewers   = 10
	UgnotPerGnot   = int64(1000000)
)

// ParseSplitsBps parses a comma-separated list of basis-point weights (e.g. "4000,3500,2500").
// Every milestone must be strictly positive and the weights must sum to exactly 10000 bps (100%).
func ParseSplitsBps(csv string) ([]int64, error) {
	trimmed := strings.TrimSpace(csv)
	if trimmed == "" {
		return nil, errors.New("splits cannot be empty")
	}

	parts := strings.Split(trimmed, ",")
	if len(parts) > MaxMilestones {
		return nil, errors.New("too many milestones (max 10)")
	}

	splits := make([]int64, len(parts))
	var total int64
	for i, raw := range parts {
		v, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
		if err != nil || v <= 0 {
			return nil, errors.New("each milestone split must be a positive integer in bps")
		}
		splits[i] = v
		total += v
	}

	if total != BpsDenominator {
		return nil, errors.New("milestone splits must sum to exactly 10000 bps")
	}
	return splits, nil
}

// ComputeMilestoneAmounts distributes totalUgnot deterministically across milestones.
// Any rounding remainder from integer division is assigned to the final milestone so
// sum(amounts) == totalUgnot holds as a strict conservation invariant (zero dust lost).
func ComputeMilestoneAmounts(totalUgnot int64, splitsBps []int64) ([]int64, error) {
	if totalUgnot <= 0 {
		return nil, errors.New("total escrow amount must be positive")
	}
	if len(splitsBps) == 0 || len(splitsBps) > MaxMilestones {
		return nil, errors.New("invalid milestone count")
	}

	var bpsSum int64
	for _, s := range splitsBps {
		if s <= 0 {
			return nil, errors.New("split weight must be positive")
		}
		bpsSum += s
	}
	if bpsSum != BpsDenominator {
		return nil, errors.New("splits must sum to 10000 bps")
	}

	amounts := make([]int64, len(splitsBps))
	var allocated int64
	for i := 0; i < len(splitsBps); i++ {
		if i == len(splitsBps)-1 {
			amounts[i] = totalUgnot - allocated
		} else {
			share := (totalUgnot * splitsBps[i]) / BpsDenominator
			amounts[i] = share
			allocated += share
		}
		if amounts[i] <= 0 {
			return nil, errors.New("escrow amount too small for milestone granularity")
		}
	}
	return amounts, nil
}

// ComputeDisputeSplit splits remainingUgnot between builder and sponsor using builderShareBps (0..10000).
func ComputeDisputeSplit(remainingUgnot, builderShareBps int64) (builderAmt int64, sponsorAmt int64, err error) {
	if remainingUgnot < 0 {
		return 0, 0, errors.New("remaining amount cannot be negative")
	}
	if builderShareBps < 0 || builderShareBps > BpsDenominator {
		return 0, 0, errors.New("builder share must be between 0 and 10000 bps")
	}
	builderAmt = (remainingUgnot * builderShareBps) / BpsDenominator
	sponsorAmt = remainingUgnot - builderAmt
	return builderAmt, sponsorAmt, nil
}

// ValidateQuorum checks that 1 <= quorum <= reviewerCount <= MaxReviewers.
func ValidateQuorum(quorum, reviewerCount int) error {
	if reviewerCount <= 0 || reviewerCount > MaxReviewers {
		return errors.New("reviewer count must be between 1 and 10")
	}
	if quorum <= 0 || quorum > reviewerCount {
		return errors.New("quorum must be between 1 and reviewer count")
	}
	return nil
}

// CalculatePoCXP computes deterministic Proof-of-Contribution XP for a paid milestone.
func CalculatePoCXP(ugnotEarned int64, onTime bool, cleanRecord bool) int64 {
	// Base 100 XP per verified milestone + 10 XP per GNOT earned (capped at +2000 XP/milestone)
	xp := int64(100)
	bonus := (ugnotEarned / UgnotPerGnot) * 10
	if bonus > 2000 {
		bonus = 2000
	}
	xp += bonus
	if onTime {
		xp += 50
	}
	if cleanRecord {
		xp += 25
	}
	return xp
}

// TierForXP maps cumulative Proof-of-Contribution XP into a readable builder badge tier.
func TierForXP(xp int64) string {
	switch {
	case xp >= 4000:
		return "Legend"
	case xp >= 1500:
		return "Master"
	case xp >= 500:
		return "Craftsman"
	default:
		return "Apprentice"
	}
}

// FormatGnot formats ugnot into a readable GNOT string (e.g. 1500000 -> "1.500000 GNOT").
func FormatGnot(ugnot int64) string {
	neg := ""
	if ugnot < 0 {
		neg = "-"
		ugnot = -ugnot
	}
	whole := ugnot / UgnotPerGnot
	frac := ugnot % UgnotPerGnot
	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	return neg + strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

// ProgressBar renders a deterministic text progress bar for gnoweb Markdown views.
func ProgressBar(released, total int64, width int) string {
	if width <= 0 {
		width = 10
	}
	if total <= 0 {
		return "[" + strings.Repeat("-", width) + "] 0%"
	}
	pct := (released * 100) / total
	if pct > 100 {
		pct = 100
	}
	if pct < 0 {
		pct = 0
	}
	filled := int((pct * int64(width)) / 100)
	return "[" + strings.Repeat("#", filled) + strings.Repeat("-", width-filled) + "] " + strconv.FormatInt(pct, 10) + "%"
}
