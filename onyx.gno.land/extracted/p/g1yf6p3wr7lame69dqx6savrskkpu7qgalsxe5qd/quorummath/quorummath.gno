// Package quorummath provides pure, deterministic escrow split math,
// quorum validation, and gnoweb formatting utilities for BountyQuorum.
package quorummath

import (
	"strconv"
	"strings"
)

const (
	// MaxBps represents 100.00% in basis points.
	MaxBps = 10000
	// UgnotPerGnot is the number of micro-GNOT in 1 GNOT.
	UgnotPerGnot = 1000000
)

// ValidateQuorum ensures quorum is strictly positive and does not exceed reviewerCount.
func ValidateQuorum(reviewerCount, quorum int) string {
	if reviewerCount <= 0 {
		return "at least one reviewer is required"
	}
	if quorum <= 0 {
		return "quorum must be at least 1"
	}
	if quorum > reviewerCount {
		return "quorum cannot exceed reviewer count"
	}
	return ""
}

// ParseCSVAddresses parses a comma-separated list of unique Gno addresses.
// Returns deduplicated addresses and an error message (empty if valid).
func ParseCSVAddresses(raw string) ([]address, string) {
	parts := strings.Split(raw, ",")
	seen := make(map[string]bool)
	out := make([]address, 0, len(parts))

	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed == "" {
			continue
		}
		a := address(trimmed)
		if !a.IsValid() {
			return nil, "invalid reviewer address: " + trimmed
		}
		key := a.String()
		if seen[key] {
			return nil, "duplicate reviewer address: " + key
		}
		seen[key] = true
		out = append(out, a)
	}
	if len(out) == 0 {
		return nil, "reviewer list cannot be empty"
	}
	return out, ""
}

// ComputeMilestonePayout computes the ugnot payout for a milestone with weightBps
// out of totalEscrow. If isLastFullAllocation is true (total allocated bps == 10000
// and this is the last unpaid milestone), it returns remainingEscrow to prevent
// integer-division dust from ever being locked in the contract.
func ComputeMilestonePayout(totalEscrow, remainingEscrow int64, weightBps int, isFinalRemainder bool) int64 {
	if remainingEscrow <= 0 || totalEscrow <= 0 || weightBps <= 0 {
		return 0
	}
	if isFinalRemainder {
		return remainingEscrow
	}
	payout := (totalEscrow * int64(weightBps)) / int64(MaxBps)
	if payout > remainingEscrow {
		return remainingEscrow
	}
	return payout
}

// QuorumOutcome determines the voting state given reviewerCount, quorum, approvals, and rejections.
// Returns "approved", "rejected", or "pending".
func QuorumOutcome(reviewerCount, quorum, approvals, rejections int) string {
	if approvals >= quorum {
		return "approved"
	}
	remaining := reviewerCount - approvals - rejections
	if approvals+remaining < quorum {
		return "rejected"
	}
	return "pending"
}

// FormatUGNOT renders a ugnot amount as human-readable GNOT plus raw ugnot.
func FormatUGNOT(amount int64) string {
	if amount < 0 {
		return "-" + FormatUGNOT(-amount)
	}
	whole := amount / UgnotPerGnot
	frac := amount % UgnotPerGnot
	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	// Trim trailing zeros down to at least 2 decimals for clean tables.
	for len(fracStr) > 2 && fracStr[len(fracStr)-1] == '0' {
		fracStr = fracStr[:len(fracStr)-1]
	}
	return strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

// ProgressBar renders a fixed-width text progress bar for gnoweb Markdown tables.
func ProgressBar(paidBps, width int) string {
	if width <= 0 {
		width = 10
	}
	if paidBps < 0 {
		paidBps = 0
	}
	if paidBps > MaxBps {
		paidBps = MaxBps
	}
	filled := (paidBps * width) / MaxBps
	var sb strings.Builder
	sb.WriteString("[")
	for i := 0; i < width; i++ {
		if i < filled {
			sb.WriteString("#")
		} else {
			sb.WriteString("-")
		}
	}
	pct := paidBps / 100
	sb.WriteString("] ")
	sb.WriteString(strconv.Itoa(pct))
	sb.WriteString("%")
	return sb.String()
}

// ShortAddr formats a Gno address compactly for tables (e.g. g1yf6p...e5qd).
func ShortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "..." + s[len(s)-4:]
}
