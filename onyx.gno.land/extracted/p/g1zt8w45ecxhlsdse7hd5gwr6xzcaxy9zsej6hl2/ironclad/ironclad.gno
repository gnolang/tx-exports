// Package ironclad provides pure, deterministic threat-class scoring, grading,
// path validation, and content-addressed audit attestation digest verification
// aligned with Gno.land's official Threat-Class Taxonomy (gno-security.md) and
// linter rules (AVL001, GLOBAL001, RENDER001).
package ironclad

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

const (
	ProtocolVersion   = "ironclad-v1"
	AttestationDomain = "ironclad-attestation-v1"

	WeightCritical = 30
	WeightHigh     = 15
	WeightMedium   = 6
	WeightLow      = 2
)

// ThreatClass describes an official Gno security threat class or lint family.
type ThreatClass struct {
	Code        string
	Title       string
	Severity    string
	Reference   string
	Remediation string
}

// ComputeScore computes a deterministic 0..100 security score from finding counts.
func ComputeScore(critical, high, medium, low int) int {
	if critical < 0 {
		critical = 0
	}
	if high < 0 {
		high = 0
	}
	if medium < 0 {
		medium = 0
	}
	if low < 0 {
		low = 0
	}
	penalty := critical*WeightCritical + high*WeightHigh + medium*WeightMedium + low*WeightLow
	if penalty >= 100 {
		return 0
	}
	return 100 - penalty
}

// ComputeGrade maps score and severe-finding gates to a letter trust grade.
func ComputeGrade(score, critical, high int) string {
	switch {
	case score == 100 && critical == 0 && high == 0:
		return "A+"
	case score >= 90 && critical == 0 && high == 0:
		return "A"
	case score >= 80 && critical == 0:
		return "B"
	case score >= 65 && critical == 0:
		return "C"
	case score >= 45:
		return "D"
	default:
		return "F"
	}
}

// IsValidHexDigest returns true iff s is a 64-char lowercase SHA-256 hex string.
func IsValidHexDigest(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < 64; i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// ValidatePkgPath ensures targetPkgPath is a well-formed Gno realm or pure
// package path (e.g. gno.land/r/user/pkg or gno.land/p/user/pkg).
func ValidatePkgPath(path string) bool {
	if len(path) < 12 || len(path) > 160 {
		return false
	}
	if !strings.HasPrefix(path, "gno.land/r/") && !strings.HasPrefix(path, "gno.land/p/") {
		return false
	}
	if strings.Contains(path, "..") || strings.Contains(path, "//") || strings.HasSuffix(path, "/") {
		return false
	}
	for i := 0; i < len(path); i++ {
		c := path[i]
		ok := (c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') ||
			c == '/' || c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

func appendLP(b *strings.Builder, s string) {
	b.WriteString(strconv.Itoa(len(s)))
	b.WriteByte(':')
	b.WriteString(s)
	b.WriteByte('|')
}

// AttestationDigest computes the canonical length-prefixed SHA-256 commitment
// binding an audit verdict to exact chain, package path, source hash, report
// digest, analyzer version, and finding counts.
func AttestationDigest(
	chainID string,
	targetPkgPath string,
	sourceHash string,
	reportDigest string,
	analyzerVersion string,
	critical int,
	high int,
	medium int,
	low int,
	info int,
) string {
	var b strings.Builder
	b.WriteString(AttestationDomain)
	b.WriteByte('|')
	appendLP(&b, chainID)
	appendLP(&b, targetPkgPath)
	appendLP(&b, sourceHash)
	appendLP(&b, reportDigest)
	appendLP(&b, analyzerVersion)
	b.WriteString(strconv.Itoa(critical))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(high))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(medium))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(low))
	b.WriteByte('|')
	b.WriteString(strconv.Itoa(info))

	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}

// VerifyAttestationDigest performs a constant-time equality check on a digest.
func VerifyAttestationDigest(
	expectedHex string,
	chainID string,
	targetPkgPath string,
	sourceHash string,
	reportDigest string,
	analyzerVersion string,
	critical, high, medium, low, info int,
) bool {
	if !IsValidHexDigest(expectedHex) {
		return false
	}
	got := AttestationDigest(
		chainID, targetPkgPath, sourceHash, reportDigest, analyzerVersion,
		critical, high, medium, low, info,
	)
	if len(got) != len(expectedHex) {
		return false
	}
	var diff byte
	for i := 0; i < len(got); i++ {
		diff |= got[i] ^ expectedHex[i]
	}
	return diff == 0
}

// Taxonomy returns a fresh slice of all official Gno security classes tracked
// by Ironclad (returning a fresh slice guarantees zero shared mutable state).
func Taxonomy() []ThreatClass {
	return []ThreatClass{
		{
			Code:        "GNO-TC1A",
			Title:       "Class-1a: cur-disclosure / impersonate-self",
			Severity:    "CRITICAL",
			Reference:   "docs/resources/gno-security.md#class-1a",
			Remediation: "Never declare interface methods taking cur realm; pass caller address derived under cur.IsCurrent().",
		},
		{
			Code:        "GNO-TC1B",
			Title:       "Class-1b: cur-disclosure / impersonate-caller",
			Severity:    "HIGH",
			Reference:   "docs/resources/gno-security.md#class-1b",
			Remediation: "Never hand live cur realm values into untrusted interface or callback calls.",
		},
		{
			Code:        "GNO-TC2",
			Title:       "Class-2: designation-forgery",
			Severity:    "CRITICAL",
			Reference:   "docs/resources/gno-security.md#class-2",
			Remediation: "Derive caller identity from cur.Previous().Address() guarded by cur.IsCurrent(); never trust address/pkgPath args.",
		},
		{
			Code:        "GNO-TC3",
			Title:       "Class-3: impl-substitution & sealing bypass",
			Severity:    "HIGH",
			Reference:   "docs/resources/gno-security.md#class-3",
			Remediation: "Enforce concrete type-switch or IsCanonical* allowlists; never rely on unexported interface sealing methods.",
		},
		{
			Code:        "GNO-TC4",
			Title:       "Class-4: closed-over-authority callback",
			Severity:    "HIGH",
			Reference:   "docs/resources/gno-security.md#class-4",
			Remediation: "Avoid invoking caller-supplied func() callbacks under realm authority; type callbacks with realm-owned types.",
		},
		{
			Code:        "GNO-SEC02",
			Title:       "Payment guard: IsUser() vs IsUserCall()",
			Severity:    "CRITICAL",
			Reference:   "docs/resources/gno-ai-contract-review.md#2",
			Remediation: "Guard OriginSend payment handlers with cur.Previous().IsUserCall(), never IsUser().",
		},
		{
			Code:        "GNO-SEC03",
			Title:       "Exported pointer to mutable state / /p/ mutator",
			Severity:    "HIGH",
			Reference:   "docs/resources/gno-ai-contract-review.md#3",
			Remediation: "Return value copies or scalar getters; never return *avl.Tree or pointers to realm state.",
		},
		{
			Code:        "GNO-SEC04",
			Title:       "Persisted realm or banker capability",
			Severity:    "CRITICAL",
			Reference:   "docs/resources/gno-ai-contract-review.md#6",
			Remediation: "Store address/pkgPath strings and mint bankers fresh per call; never persist realm or banker.Banker in globals.",
		},
		{
			Code:        "GNO-SEC05",
			Title:       "chain/runtime/unsafe stack-walk alongside cur realm",
			Severity:    "HIGH",
			Reference:   "docs/resources/gno-ai-contract-review.md#9",
			Remediation: "Replace unsafe.PreviousRealm()/CurrentRealm()/OriginCaller() with cur.Previous()/cur.Address().",
		},
		{
			Code:        "GNO-SEC06",
			Title:       "Unsanitized Render(path) Markdown injection",
			Severity:    "MEDIUM",
			Reference:   "docs/resources/gno-ai-contract-review.md#10",
			Remediation: "Escape user strings with gno.land/p/nt/markdown/sanitize/v0 (InlineText, TableCell, URL, Block).",
		},
		{
			Code:        "GNO-SEC07",
			Title:       "Unbounded GetCoins() single-denom lookup DoS",
			Severity:    "MEDIUM",
			Reference:   "docs/resources/gno-ai-contract-review.md#11",
			Remediation: "Use O(1) banker.GetCoin(addr, denom) instead of GetCoins(addr).AmountOf(denom).",
		},
		{
			Code:        "AVL001",
			Title:       "Unbounded avl.Tree iteration DoS",
			Severity:    "MEDIUM",
			Reference:   "gnolang/gno#5068",
			Remediation: "Use IterateByOffset / ReverseIterateByOffset or enforce an explicit row limit in callbacks.",
		},
		{
			Code:        "GLOBAL001",
			Title:       "Exported mutable global variable in realm",
			Severity:    "MEDIUM",
			Reference:   "gnolang/gno#5068",
			Remediation: "Keep realm state unexported and expose controlled read-only getters.",
		},
		{
			Code:        "RENDER001",
			Title:       "State mutation inside Render(path)",
			Severity:    "MEDIUM",
			Reference:   "gnolang/gno#5068",
			Remediation: "Keep Render strictly pure and side-effect free.",
		},
	}
}
