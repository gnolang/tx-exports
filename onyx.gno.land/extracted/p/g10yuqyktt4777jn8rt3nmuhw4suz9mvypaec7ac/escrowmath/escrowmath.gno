// Package escrowmath provides pure, deterministic escrow payout math,
// basis-point splitting with zero dust loss, GNOT formatting, reputation
// tier mapping, and safe Markdown rendering helpers for Gno.land realms.
package escrowmath

import (
	"errors"
	"strconv"
	"strings"
)

const (
	// TotalBPS represents 100.00% in basis points.
	TotalBPS int64 = 10000
	// UgnotPerGnot is the base denomination factor (1 GNOT = 1,000,000 ugnot).
	UgnotPerGnot int64 = 1000000
)

var (
	ErrInvalidAmount = errors.New("escrowmath: total amount must be positive")
	ErrEmptyWeights  = errors.New("escrowmath: basis-point weights cannot be empty")
	ErrInvalidWeight = errors.New("escrowmath: each weight must be positive")
	ErrWeightSum     = errors.New("escrowmath: basis-point weights must sum to 10000")
)

// SplitBasisPoints divides total into exact integer shares proportional to bps.
// Any integer-division remainder (dust) is awarded to the recipient with the
// largest basis-point weight (ties broken by lowest index) so that the sum of
// returned shares is guaranteed to equal total.
func SplitBasisPoints(total int64, bps []int64) ([]int64, error) {
	if total <= 0 {
		return nil, ErrInvalidAmount
	}
	if len(bps) == 0 {
		return nil, ErrEmptyWeights
	}

	var sum int64
	maxIdx := 0
	for i, w := range bps {
		if w <= 0 {
			return nil, ErrInvalidWeight
		}
		sum += w
		if w > bps[maxIdx] {
			maxIdx = i
		}
	}
	if sum != TotalBPS {
		return nil, ErrWeightSum
	}

	shares := make([]int64, len(bps))
	var distributed int64
	for i, w := range bps {
		// Overflow-safe computation: (total / TotalBPS) * w + ((total % TotalBPS) * w) / TotalBPS
		q := total / TotalBPS
		r := total % TotalBPS
		share := q*w + (r*w)/TotalBPS
		shares[i] = share
		distributed += share
	}

	remainder := total - distributed
	if remainder > 0 {
		shares[maxIdx] += remainder
	}
	return shares, nil
}

// ComputeXP calculates reputation XP earned for completing a bounty funded with ugnot.
func ComputeXP(ugnot int64) int64 {
	if ugnot <= 0 {
		return 0
	}
	bonus := ugnot / 100000 // +10 XP per 1 GNOT (1,000,000 ugnot)
	if bonus > 5000 {
		bonus = 5000
	}
	return 100 + bonus
}

// TierForXP maps accumulated contributor XP to a deterministic tier label and badge.
func TierForXP(xp int64) (string, string) {
	switch {
	case xp >= 5000:
		return "Grandmaster", "[GM]"
	case xp >= 2000:
		return "Master", "[M]"
	case xp >= 800:
		return "Artisan", "[A]"
	case xp >= 300:
		return "Journeyman", "[J]"
	case xp >= 100:
		return "Apprentice", "[AP]"
	default:
		return "Novice", "[N]"
	}
}

// FormatGNOT formats an integer ugnot amount into a clean GNOT string (e.g. "1.5 GNOT").
func FormatGNOT(ugnot int64) string {
	neg := false
	if ugnot < 0 {
		neg = true
		ugnot = -ugnot
	}
	whole := ugnot / UgnotPerGnot
	frac := ugnot % UgnotPerGnot

	var b strings.Builder
	if neg {
		b.WriteByte('-')
	}
	b.WriteString(strconv.FormatInt(whole, 10))
	if frac > 0 {
		b.WriteByte('.')
		fracStr := strconv.FormatInt(frac, 10)
		for i := len(fracStr); i < 6; i++ {
			b.WriteByte('0')
		}
		b.WriteString(fracStr)
		// Trim trailing zeroes after decimal point
		out := strings.TrimRight(b.String(), "0")
		return out + " GNOT"
	}
	return b.String() + " GNOT"
}

// ProgressBar renders a fixed-width ASCII progress bar for gnoweb Markdown views.
func ProgressBar(done, total, width int) string {
	if width <= 0 {
		width = 10
	}
	filled := 0
	if total > 0 && done > 0 {
		if done >= total {
			filled = width
		} else {
			filled = (done * width) / total
		}
	}
	var b strings.Builder
	b.WriteByte('[')
	for i := 0; i < width; i++ {
		if i < filled {
			b.WriteByte('#')
		} else {
			b.WriteByte('-')
		}
	}
	b.WriteByte(']')
	return b.String()
}

// SanitizeInline strips line breaks and Markdown table pipes and truncates cleanly.
func SanitizeInline(s string, maxLen int) string {
	s = strings.TrimSpace(s)
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "|", "/")
	if maxLen > 0 && len(s) > maxLen {
		if maxLen > 3 {
			return s[:maxLen-3] + "..."
		}
		return s[:maxLen]
	}
	return s
}
