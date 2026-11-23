// Package escrowmath provides pure, deterministic escrow payout math,
// overflow-proof basis-point splitting, Hamilton pro-rata sponsor refunds,
// GNOT/BPS formatting, reputation tier mapping, and UTF-8-safe text helpers
// for Gno.land realms.
package escrowmath

import (
	"errors"
	"math/bits"
	"math/overflow"
	"strconv"
	"strings"
)

const (
	// TotalBPS represents 100.00% in basis points.
	TotalBPS int64 = 10000
	// UgnotPerGnot is the base denomination factor (1 GNOT = 1,000,000 ugnot).
	UgnotPerGnot int64 = 1000000
	// MaxProgressBarWidth bounds ProgressBar allocation against untrusted widths.
	MaxProgressBarWidth = 64
)

var (
	ErrInvalidAmount         = errors.New("escrowmath: total amount must be positive")
	ErrEmptyWeights          = errors.New("escrowmath: basis-point weights cannot be empty")
	ErrInvalidWeight         = errors.New("escrowmath: each weight must be in 1..10000")
	ErrWeightSum             = errors.New("escrowmath: basis-point weights must sum to 10000")
	ErrZeroShare             = errors.New("escrowmath: split weight produces a zero-ugnot share")
	ErrEmptyDeposits         = errors.New("escrowmath: deposits cannot be empty")
	ErrInvalidDeposit        = errors.New("escrowmath: each deposit must be positive")
	ErrDepositOverflow       = errors.New("escrowmath: total deposits overflow int64")
	ErrInvalidRefund         = errors.New("escrowmath: refund amount must be non-negative")
	ErrRefundExceedsDeposits = errors.New("escrowmath: refund exceeds total deposits")
)

// SplitBasisPoints divides total into exact positive integer shares proportional
// to bps using overflow-safe arithmetic. Any integer-division remainder (dust)
// is awarded to the recipient with the largest basis-point weight (ties broken
// by lowest index) so that sum(shares) == total and every share > 0.
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
		if w <= 0 || w > TotalBPS {
			return nil, ErrInvalidWeight
		}
		var ok bool
		sum, ok = overflow.Add64(sum, w)
		if !ok || sum > TotalBPS {
			return nil, ErrWeightSum
		}
		if w > bps[maxIdx] {
			maxIdx = i
		}
	}
	if sum != TotalBPS {
		return nil, ErrWeightSum
	}

	shares := make([]int64, len(bps))
	q := total / TotalBPS
	r := total % TotalBPS
	var distributed int64
	for i, w := range bps {
		// Because 0 < w <= TotalBPS (10000):
		//   q*w <= (total/10000)*10000 <= total <= MaxInt64
		//   r*w <= 9999*10000 = 99,990,000 (never overflows int64)
		share := q*w + (r*w)/TotalBPS
		shares[i] = share
		distributed += share
	}

	remainder := total - distributed
	if remainder > 0 {
		shares[maxIdx] += remainder
	}

	var verify int64
	for _, s := range shares {
		if s <= 0 {
			return nil, ErrZeroShare
		}
		verify += s
	}
	if verify != total {
		return nil, ErrInvalidAmount
	}
	return shares, nil
}

// ProRataRefund distributes refundPool across deposits proportionally using
// 128-bit overflow-proof math and Hamilton largest-remainder apportionment.
// Guarantees:
//   - sum(refunds) == refundPool (zero dust loss)
//   - 0 <= refunds[i] <= deposits[i] for every contributor
func ProRataRefund(refundPool int64, deposits []int64) ([]int64, error) {
	if refundPool < 0 {
		return nil, ErrInvalidRefund
	}
	if len(deposits) == 0 {
		return nil, ErrEmptyDeposits
	}

	var totalDep int64
	for _, d := range deposits {
		if d <= 0 {
			return nil, ErrInvalidDeposit
		}
		var ok bool
		totalDep, ok = overflow.Add64(totalDep, d)
		if !ok {
			return nil, ErrDepositOverflow
		}
	}
	if refundPool > totalDep {
		return nil, ErrRefundExceedsDeposits
	}

	refunds := make([]int64, len(deposits))
	if refundPool == 0 {
		return refunds, nil
	}
	if refundPool == totalDep {
		copy(refunds, deposits)
		return refunds, nil
	}

	// 0 < refundPool < totalDep <= MaxInt64 guarantees hi < uint64(totalDep),
	// so bits.Div64 can never overflow or panic.
	rems := make([]uint64, len(deposits))
	var distributed int64
	for i, d := range deposits {
		hi, lo := bits.Mul64(uint64(refundPool), uint64(d))
		quo, rem := bits.Div64(hi, lo, uint64(totalDep))
		refunds[i] = int64(quo)
		rems[i] = rem
		distributed += int64(quo)
	}

	// Distribute leftover ugnot (at most len(deposits)-1) via largest remainder,
	// breaking ties by largest deposit then lowest index (creator-first).
	// Every selected index has rem > 0, which mathematically guarantees
	// refunds[i] < deposits[i] so refunds[i]+1 <= deposits[i].
	leftover := int(refundPool - distributed)
	used := make([]bool, len(deposits))
	for step := 0; step < leftover; step++ {
		best := -1
		for i := range deposits {
			if used[i] || refunds[i] >= deposits[i] {
				continue
			}
			if best == -1 ||
				rems[i] > rems[best] ||
				(rems[i] == rems[best] && deposits[i] > deposits[best]) {
				best = i
			}
		}
		if best == -1 {
			break
		}
		refunds[best]++
		used[best] = true
	}

	return refunds, nil
}

// ComputeXP calculates value-weighted reputation XP earned from a settled payout.
// Micro-bounties (< 0.1 GNOT) yield minimal XP (1 XP base) to resist Sybil wash-farming,
// while real bounties scale linearly (+25 XP per 1 GNOT, capped at 2500 bonus per payout).
func ComputeXP(ugnot int64) int64 {
	if ugnot <= 0 {
		return 0
	}
	base := int64(1)
	if ugnot >= 100000 { // >= 0.1 GNOT
		base = 10
	}
	bonus := ugnot / 40000 // +25 XP per 1 GNOT (1,000,000 ugnot)
	if bonus > 2500 {
		bonus = 2500
	}
	return base + bonus
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

// TierColor returns the deterministic hex accent color for a builder's XP tier.
func TierColor(xp int64) string {
	switch {
	case xp >= 5000:
		return "#F59E0B"
	case xp >= 2000:
		return "#A855F7"
	case xp >= 800:
		return "#3B82F6"
	case xp >= 300:
		return "#10B981"
	case xp >= 100:
		return "#06B6D4"
	default:
		return "#64748B"
	}
}

// FormatGNOT formats an integer ugnot amount into a clean GNOT string (e.g. "1.5 GNOT").
// Safe for all int64 values including math.MinInt64.
func FormatGNOT(ugnot int64) string {
	neg := ugnot < 0
	var mag uint64
	if neg {
		mag = uint64(-(ugnot + 1)) + 1
	} else {
		mag = uint64(ugnot)
	}
	whole := mag / uint64(UgnotPerGnot)
	frac := mag % uint64(UgnotPerGnot)

	var b strings.Builder
	if neg {
		b.WriteByte('-')
	}
	b.WriteString(strconv.FormatUint(whole, 10))
	if frac > 0 {
		b.WriteByte('.')
		fracStr := strconv.FormatUint(frac, 10)
		for i := len(fracStr); i < 6; i++ {
			b.WriteByte('0')
		}
		b.WriteString(fracStr)
		out := strings.TrimRight(b.String(), "0")
		return out + " GNOT"
	}
	return b.String() + " GNOT"
}

// FormatBPS formats basis points (e.g. 6667 -> "66.67%", 7500 -> "75%") using
// pure integer arithmetic (zero float64).
func FormatBPS(bps int64) string {
	neg := bps < 0
	var mag uint64
	if neg {
		mag = uint64(-(bps + 1)) + 1
	} else {
		mag = uint64(bps)
	}
	whole := mag / 100
	frac := mag % 100

	var b strings.Builder
	if neg {
		b.WriteByte('-')
	}
	b.WriteString(strconv.FormatUint(whole, 10))
	if frac > 0 {
		b.WriteByte('.')
		if frac < 10 {
			b.WriteByte('0')
		}
		b.WriteString(strconv.FormatUint(frac, 10))
		return strings.TrimRight(b.String(), "0") + "%"
	}
	return b.String() + "%"
}

// ProgressBar renders a bounded, overflow-safe ASCII progress bar for Markdown views.
func ProgressBar(done, total, width int) string {
	if width <= 0 {
		width = 10
	}
	if width > MaxProgressBarWidth {
		width = MaxProgressBarWidth
	}
	filled := 0
	if total > 0 && done > 0 {
		if done >= total {
			filled = width
		} else {
			hi, lo := bits.Mul64(uint64(done), uint64(width))
			quo, _ := bits.Div64(hi, lo, uint64(total))
			filled = int(quo)
		}
	}
	var b strings.Builder
	b.Grow(width + 2)
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

// TruncateRunes truncates s to at most maxRunes Unicode code points without
// splitting multi-byte UTF-8 sequences.
func TruncateRunes(s string, maxRunes int) string {
	if maxRunes <= 0 {
		return s
	}
	runes := []rune(s)
	if len(runes) <= maxRunes {
		return s
	}
	if maxRunes > 3 {
		return string(runes[:maxRunes-3]) + "..."
	}
	return string(runes[:maxRunes])
}

// SanitizeInline normalizes control/line-break characters and truncates rune-safely.
// For rendered Markdown slots inside realms, always prefer gno.land/p/nt/markdown/sanitize/v0.
func SanitizeInline(s string, maxRunes int) string {
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range strings.TrimSpace(s) {
		switch {
		case r == '\r' || r == '\n' || r == '\t' || r == 0x0085 || r == 0x2028 || r == 0x2029:
			b.WriteByte(' ')
		case r == '|':
			b.WriteByte('/')
		case r == 0:
			b.WriteRune(0xFFFD)
		case (r >= 0x200B && r <= 0x200F) || (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069) || r == 0xFEFF:
			// strip bidi / zero-width spoofing controls
		default:
			b.WriteRune(r)
		}
	}
	return TruncateRunes(strings.TrimSpace(b.String()), maxRunes)
}
