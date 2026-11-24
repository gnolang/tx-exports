package hearthbounty

import "strings"

func asciiLowerByte(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

func hasASCIIPrefixFold(s string, pos int, pattern string) bool {
	if pos+len(pattern) > len(s) {
		return false
	}
	for j := 0; j < len(pattern); j++ {
		if asciiLowerByte(s[pos+j]) != pattern[j] {
			return false
		}
	}
	return true
}

// NeutralizeGnoTags escapes any <gno- or </gno- tag sequences using direct
// byte-indexed ASCII case folding on the original string. Avoiding strings.ToLower
// prevents multi-byte Unicode case expansions (such as U+0130 'İ' -> "i\u0307")
// from shifting slice indices and letting raw <gno-*> tags pass through.
func NeutralizeGnoTags(s string) string {
	var b strings.Builder
	changed := false
	for i := 0; i < len(s); i++ {
		if s[i] == '<' && (hasASCIIPrefixFold(s, i, "<gno-") || hasASCIIPrefixFold(s, i, "</gno-")) {
			if !changed {
				b.Grow(len(s) + 8)
				b.WriteString(s[:i])
				changed = true
			}
			b.WriteString("&lt;")
			continue
		}
		if changed {
			b.WriteByte(s[i])
		}
	}
	if !changed {
		return s
	}
	return b.String()
}

// ValidateProofURL enforces HTTPS-only deliverable links with no whitespace so
// rendered proof links always survive p/nt/markdown/sanitize/v0 intact.
func ValidateProofURL(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if len(trimmed) < 12 {
		panic("hearthbounty: proof URL is too short")
	}
	if len(trimmed) > 300 {
		panic("hearthbounty: proof URL exceeds maximum length")
	}
	if !strings.HasPrefix(trimmed, "https://") {
		panic("hearthbounty: proof URL must start with https://")
	}
	if strings.ContainsAny(trimmed, " \t\r\n") {
		panic("hearthbounty: proof URL must not contain whitespace")
	}
	return trimmed
}
