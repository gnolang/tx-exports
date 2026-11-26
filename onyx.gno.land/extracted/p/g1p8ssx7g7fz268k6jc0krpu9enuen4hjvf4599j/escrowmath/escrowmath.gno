// Package escrowmath provides pure, deterministic arithmetic, quorum tallying,
// split conservation, formatting, and JSON encoding utilities for MilestoneVault
// and any third-party Gno.land escrow or bounty realms.
package escrowmath

import (
	"errors"
	"strconv"
	"strings"
)

const (
	MaxMilestones  = 12
	MaxArbiters    = 5
	BpsDenominator = int64(10000)
	UgnotPerGnot   = int64(1000000)
	MaxSafeAmount  = int64(900000000000000) // 900M GNOT guard against int64 bps overflow
)

var (
	ErrNoMilestones       = errors.New("at least one milestone is required")
	ErrTooManyMilestones  = errors.New("exceeds maximum milestone count (12)")
	ErrInvalidAmount      = errors.New("milestone amount must be positive and within safe bounds")
	ErrDepositMismatch    = errors.New("sum of milestone amounts must equal exact deposit sent")
	ErrInvalidArbiterList = errors.New("arbiter count must be between 1 and 5")
)

// ValidateMilestones verifies every milestone amount is positive, overflow-safe,
// sums strictly to totalDeposit, and returns proportional basis points (0..10000).
func ValidateMilestones(amounts []int64, totalDeposit int64) ([]int64, error) {
	if len(amounts) == 0 {
		return nil, ErrNoMilestones
	}
	if len(amounts) > MaxMilestones {
		return nil, ErrTooManyMilestones
	}
	if totalDeposit <= 0 || totalDeposit > MaxSafeAmount {
		return nil, ErrInvalidAmount
	}

	var sum int64
	for _, a := range amounts {
		if a <= 0 || a > MaxSafeAmount {
			return nil, ErrInvalidAmount
		}
		if sum > MaxSafeAmount-a {
			return nil, ErrInvalidAmount
		}
		sum += a
	}
	if sum != totalDeposit {
		return nil, ErrDepositMismatch
	}

	bps := make([]int64, len(amounts))
	var bpsSum int64
	for i, a := range amounts {
		share := (a * BpsDenominator) / totalDeposit
		bps[i] = share
		bpsSum += share
	}
	// Assign any integer rounding remainder to the final milestone so bps sums to 10000.
	if bpsSum < BpsDenominator {
		bps[len(bps)-1] += BpsDenominator - bpsSum
	}
	return bps, nil
}

// QuorumThreshold returns the strict majority needed for an arbiter council of size n.
func QuorumThreshold(arbiterCount int) int {
	if arbiterCount <= 0 {
		return 1
	}
	return (arbiterCount / 2) + 1
}

// EvaluateDisputeTally checks whether any dispute verdict has reached strict majority.
// If all arbiters have cast votes and no single verdict reached majority (deadlock),
// it deterministically resolves to "SPLIT" so escrowed funds can never be trapped.
func EvaluateDisputeTally(releaseVotes, refundVotes, splitVotes, arbiterCount int) (string, bool) {
	q := QuorumThreshold(arbiterCount)
	if releaseVotes >= q {
		return "RELEASE", true
	}
	if refundVotes >= q {
		return "REFUND", true
	}
	if splitVotes >= q {
		return "SPLIT", true
	}
	totalVotes := releaseVotes + refundVotes + splitVotes
	if arbiterCount > 0 && totalVotes >= arbiterCount {
		return "SPLIT", true
	}
	return "", false
}

// ComputeSplit divides an escrowed milestone 50/50 between builder and sponsor
// while strictly conserving every ugnot (builder receives the 1 ugnot remainder if odd).
func ComputeSplit(amount int64) (builderShare int64, sponsorShare int64) {
	if amount <= 0 {
		return 0, 0
	}
	sponsorShare = amount / 2
	builderShare = amount - sponsorShare
	return builderShare, sponsorShare
}

// FormatUGNOT formats an integer ugnot balance into a clean GNOT display string.
func FormatUGNOT(amount int64) string {
	neg := false
	if amount < 0 {
		neg = true
		amount = -amount
	}
	whole := amount / UgnotPerGnot
	frac := amount % UgnotPerGnot

	prefix := ""
	if neg {
		prefix = "-"
	}
	if frac == 0 {
		return prefix + strconv.FormatInt(whole, 10) + " GNOT"
	}

	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	fracStr = strings.TrimRight(fracStr, "0")
	return prefix + strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

// RenderProgressBar produces a deterministic Unicode bar for gnoweb Markdown views.
func RenderProgressBar(completed, total int64, width int) string {
	if width <= 0 {
		width = 16
	}
	pct := int64(0)
	if total > 0 {
		if completed > total {
			completed = total
		}
		if completed < 0 {
			completed = 0
		}
		pct = (completed * 100) / total
	}
	filled := int((pct * int64(width)) / 100)
	if filled > width {
		filled = width
	}
	var sb strings.Builder
	sb.WriteString("[")
	for i := 0; i < width; i++ {
		if i < filled {
			sb.WriteString("█")
		} else {
			sb.WriteString("░")
		}
	}
	sb.WriteString("] ")
	sb.WriteString(strconv.FormatInt(pct, 10))
	sb.WriteString("%")
	return sb.String()
}

// SplitPipe splits a pipe-delimited string and trims whitespace from non-empty items.
func SplitPipe(input string) []string {
	if strings.TrimSpace(input) == "" {
		return nil
	}
	raw := strings.Split(input, "|")
	out := make([]string, 0, len(raw))
	for _, s := range raw {
		t := strings.TrimSpace(s)
		if t != "" {
			out = append(out, t)
		}
	}
	return out
}

// SplitCSV splits a comma-delimited string and trims whitespace from non-empty items.
func SplitCSV(input string) []string {
	if strings.TrimSpace(input) == "" {
		return nil
	}
	raw := strings.Split(input, ",")
	out := make([]string, 0, len(raw))
	for _, s := range raw {
		t := strings.TrimSpace(s)
		if t != "" {
			out = append(out, t)
		}
	}
	return out
}

// ParseAmountsCSV parses comma-separated positive ugnot integers.
func ParseAmountsCSV(input string) ([]int64, error) {
	parts := SplitCSV(input)
	if len(parts) == 0 {
		return nil, ErrNoMilestones
	}
	out := make([]int64, len(parts))
	for i, p := range parts {
		v, err := strconv.ParseInt(p, 10, 64)
		if err != nil || v <= 0 {
			return nil, ErrInvalidAmount
		}
		out[i] = v
	}
	return out, nil
}

// EscapeJSON escapes control characters and quotes for deterministic JSON rendering.
func EscapeJSON(s string) string {
	var sb strings.Builder
	sb.Grow(len(s) + 8)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			sb.WriteString(`\"`)
		case '\\':
			sb.WriteString(`\\`)
		case '\n':
			sb.WriteString(`\n`)
		case '\r':
			sb.WriteString(`\r`)
		case '\t':
			sb.WriteString(`\t`)
		default:
			if c < 0x20 {
				sb.WriteString(" ")
			} else {
				sb.WriteByte(c)
			}
		}
	}
	return sb.String()
}
