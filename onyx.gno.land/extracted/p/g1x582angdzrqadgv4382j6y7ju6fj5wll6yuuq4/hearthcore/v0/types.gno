// Package hearthcore provides deterministic escrow math, bounty lifecycle
// primitives, reputation tier calculation, RFC-8259 JSON encoding, and
// on-chain SVG visual builders for HearthBounty and any Gno.land realm that
// imports it.
package hearthcore

import (
	"strconv"
	"strings"
)

const (
	// Denom is the native settlement denomination on Gno.land.
	Denom = "ugnot"

	// UgnotPerGNOT is the number of micro-GNOT in 1 GNOT.
	UgnotPerGNOT int64 = 1000000

	// MinRewardUgnot enforces a 0.1 GNOT floor to discourage dust spam.
	MinRewardUgnot int64 = 100000

	// Deadline block bounds ensure deterministic block-height timeouts.
	MinDeadlineBlocks     int64 = 10
	MaxDeadlineBlocks     int64 = 2000000
	DefaultDeadlineBlocks int64 = 50000

	// MaxBps represents 100.00% in integer basis points.
	MaxBps uint64 = 10000

	// Text length limits keep storage deposits bounded and predictable.
	MaxTitleLen    = 120
	MaxSpecLen     = 4000
	MaxNoteLen     = 600
	MaxURLLen      = 300
	MaxDigestLen   = 128
	MaxHandleLen   = 40
	MaxBioLen      = 300
	MaxSkillsLen   = 200
	MaxEndpointLen = 240
)

// Status represents a bounty's lifecycle state.
type Status string

const (
	StatusOpen      Status = "open"
	StatusClaimed   Status = "claimed"
	StatusSubmitted Status = "submitted"
	StatusDisputed  Status = "disputed"
	StatusSettled   Status = "settled"
	StatusCancelled Status = "cancelled"
)

// IsValid reports whether s is a known lifecycle status.
func (s Status) IsValid() bool {
	switch s {
	case StatusOpen, StatusClaimed, StatusSubmitted, StatusDisputed, StatusSettled, StatusCancelled:
		return true
	default:
		return false
	}
}

// Label returns a concise display label for s.
func (s Status) Label() string {
	switch s {
	case StatusOpen:
		return "Open"
	case StatusClaimed:
		return "Claimed"
	case StatusSubmitted:
		return "Submitted"
	case StatusDisputed:
		return "Disputed"
	case StatusSettled:
		return "Settled"
	case StatusCancelled:
		return "Cancelled"
	default:
		return "Unknown"
	}
}

// IconName returns a verified gnoweb icon identifier for s.
func (s Status) IconName() string {
	switch s {
	case StatusOpen:
		return "flame"
	case StatusClaimed:
		return "clock"
	case StatusSubmitted:
		return "upload"
	case StatusDisputed:
		return "warning"
	case StatusSettled:
		return "check-circle"
	case StatusCancelled:
		return "trash"
	default:
		return "info"
	}
}

// StepIndex returns the 0-based progression index for active lifecycle steps.
func (s Status) StepIndex() int {
	switch s {
	case StatusOpen:
		return 0
	case StatusClaimed:
		return 1
	case StatusSubmitted:
		return 2
	case StatusSettled:
		return 3
	case StatusDisputed:
		return 2
	default:
		return -1
	}
}

// Category classifies the kind of engineering work a bounty requests.
type Category string

const (
	CatRealm Category = "realm"
	CatTool  Category = "tool"
	CatAudit Category = "audit"
	CatDocs  Category = "docs"
	CatAgent Category = "agent"
)

// AllCategories returns all supported categories in canonical order.
func AllCategories() []Category {
	return []Category{CatRealm, CatTool, CatAudit, CatDocs, CatAgent}
}

// ParseCategory normalizes and validates a category string.
func ParseCategory(raw string) (Category, bool) {
	c := Category(strings.ToLower(strings.TrimSpace(raw)))
	switch c {
	case CatRealm, CatTool, CatAudit, CatDocs, CatAgent:
		return c, true
	default:
		return "", false
	}
}

// Label returns a human-friendly title for c.
func (c Category) Label() string {
	switch c {
	case CatRealm:
		return "Realm"
	case CatTool:
		return "Tooling"
	case CatAudit:
		return "Security Audit"
	case CatDocs:
		return "Docs & Guides"
	case CatAgent:
		return "AI Agent"
	default:
		return "General"
	}
}

// IconName returns a verified gnoweb icon identifier for c.
func (c Category) IconName() string {
	switch c {
	case CatRealm:
		return "code"
	case CatTool:
		return "settings"
	case CatAudit:
		return "shield"
	case CatDocs:
		return "book"
	case CatAgent:
		return "ai"
	default:
		return "tag"
	}
}

// Tier represents a builder or agent's earned on-chain reputation rank.
type Tier string

const (
	TierApprentice  Tier = "Apprentice"
	TierJourneyman  Tier = "Journeyman"
	TierMaster      Tier = "Master"
	TierGuildmaster Tier = "Guildmaster"
)

// ComputeTier deterministically assigns a reputation tier using pure integer math.
func ComputeTier(settledCount uint64, earnedUgnot int64, ratingSum uint64, ratingCount uint64) Tier {
	highQuality := ratingCount == 0 || ratingSum*10 >= ratingCount*45
	if (settledCount >= 10 || earnedUgnot >= 500*UgnotPerGNOT) && highQuality {
		return TierGuildmaster
	}
	if settledCount >= 5 || earnedUgnot >= 100*UgnotPerGNOT {
		return TierMaster
	}
	if settledCount >= 2 || earnedUgnot >= 10*UgnotPerGNOT {
		return TierJourneyman
	}
	return TierApprentice
}

// TierColor returns a high-contrast hex accent color for SVG badges.
func (t Tier) Color() string {
	switch t {
	case TierGuildmaster:
		return "#f59e0b"
	case TierMaster:
		return "#a78bfa"
	case TierJourneyman:
		return "#38bdf8"
	default:
		return "#34d399"
	}
}

// ComputeSplit splits an escrowed ugnot balance between hunter and sponsor
// using integer basis points (0..10000). It guarantees exact conservation:
// hunterUgnot + sponsorRefundUgnot == escrowUgnot.
func ComputeSplit(escrowUgnot int64, hunterBps uint64) (hunterUgnot int64, sponsorRefundUgnot int64) {
	if escrowUgnot < 0 {
		panic("hearthcore: negative escrow amount")
	}
	if hunterBps > MaxBps {
		panic("hearthcore: hunterBps exceeds 10000")
	}
	if hunterBps == 0 {
		return 0, escrowUgnot
	}
	if hunterBps == MaxBps {
		return escrowUgnot, 0
	}
	// Divide first to prevent int64 multiplication overflow on large balances.
	q := escrowUgnot / int64(MaxBps)
	r := escrowUgnot % int64(MaxBps)
	hunterUgnot = q*int64(hunterBps) + (r*int64(hunterBps))/int64(MaxBps)
	sponsorRefundUgnot = escrowUgnot - hunterUgnot
	return hunterUgnot, sponsorRefundUgnot
}

// FormatGNOT formats micro-GNOT into a deterministic human-readable GNOT string
// without floating-point operations.
func FormatGNOT(ugnot int64) string {
	neg := false
	if ugnot < 0 {
		neg = true
		ugnot = -ugnot
	}
	whole := ugnot / UgnotPerGNOT
	frac := ugnot % UgnotPerGNOT

	prefix := ""
	if neg {
		prefix = "-"
	}
	if frac == 0 {
		return prefix + strconv.FormatInt(whole, 10) + ".00 GNOT"
	}

	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	// Keep at least 2 decimal digits, trimming trailing zeros beyond 2.
	trimmed := strings.TrimRight(fracStr, "0")
	if len(trimmed) < 2 {
		trimmed = fracStr[:2]
	}
	return prefix + strconv.FormatInt(whole, 10) + "." + trimmed + " GNOT"
}

// FormatRating formats an integer rating sum/count into "X.Y / 5.0" or "Unrated".
func FormatRating(sum uint64, count uint64) string {
	if count == 0 {
		return "Unrated"
	}
	tenths := (sum*10 + count/2) / count
	whole := tenths / 10
	rem := tenths % 10
	return strconv.FormatUint(whole, 10) + "." + strconv.FormatUint(rem, 10) + " / 5.0"
}

// ShortAddr shortens a bech32 Gno address for compact tables and badges.
func ShortAddr(addr address) string {
	s := string(addr)
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "..." + s[len(s)-4:]
}

// EscapeMath neutralizes unescaped dollar signs after Markdown sanitization so
// gnoweb's math extension does not treat prices or user text as TeX formulas.
func EscapeMath(s string) string {
	return strings.ReplaceAll(s, "$", `\$`)
}

// NeutralizeGnoTags escapes any remaining <gno- or </gno- tag sequences
// (case-insensitive) as defense-in-depth on top of p/nt/markdown/sanitize/v0
// so user-authored text can never smuggle gnoweb UI directives.
func NeutralizeGnoTags(s string) string {
	lower := strings.ToLower(s)
	if !strings.Contains(lower, "<gno-") && !strings.Contains(lower, "</gno-") {
		return s
	}
	var b strings.Builder
	b.Grow(len(s) + 8)
	for i := 0; i < len(s); i++ {
		if s[i] == '<' {
			rem := lower[i:]
			if strings.HasPrefix(rem, "<gno-") || strings.HasPrefix(rem, "</gno-") {
				b.WriteString("&lt;")
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// ValidateText verifies a required or optional text field within rune/byte bounds.
func ValidateText(field, value string, minLen, maxLen int) string {
	trimmed := strings.TrimSpace(value)
	if len(trimmed) < minLen {
		panic("hearthcore: " + field + " is too short")
	}
	if len(trimmed) > maxLen {
		panic("hearthcore: " + field + " exceeds maximum length")
	}
	return trimmed
}

// ValidateProofURL enforces safe http/https/ipfs proof links.
func ValidateProofURL(raw string) string {
	trimmed := ValidateText("proof URL", raw, 8, MaxURLLen)
	if !strings.HasPrefix(trimmed, "https://") &&
		!strings.HasPrefix(trimmed, "http://") &&
		!strings.HasPrefix(trimmed, "ipfs://") {
		panic("hearthcore: proof URL must start with https://, http://, or ipfs://")
	}
	if strings.ContainsAny(trimmed, " \t\r\n") {
		panic("hearthcore: proof URL must not contain whitespace")
	}
	return trimmed
}

// ValidateProofDigest verifies a non-empty hexadecimal or prefixed content digest.
func ValidateProofDigest(raw string) string {
	trimmed := ValidateText("proof digest", raw, 8, MaxDigestLen)
	if strings.ContainsAny(trimmed, " \t\r\n") {
		panic("hearthcore: proof digest must not contain whitespace")
	}
	return trimmed
}

// ValidateDeadlineBlocks checks that a bounty deadline window is within safe bounds.
func ValidateDeadlineBlocks(blocks int64) int64 {
	if blocks == 0 {
		return DefaultDeadlineBlocks
	}
	if blocks < MinDeadlineBlocks || blocks > MaxDeadlineBlocks {
		panic("hearthcore: deadlineBlocks out of allowed range")
	}
	return blocks
}

// ValidateRating checks that a settlement rating is in [1, 5].
func ValidateRating(rating uint8) uint8 {
	if rating < 1 || rating > 5 {
		panic("hearthcore: rating must be between 1 and 5")
	}
	return rating
}
