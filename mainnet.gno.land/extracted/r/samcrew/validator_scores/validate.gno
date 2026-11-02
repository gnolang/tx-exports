package validator_scores

import (
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	maxMonikerBytes = 64
	maxArenas       = 16
	maxArenaName    = 32
	maxScore        = 10000 // 100.00 in hundredths: total and each arena score
	maxGithub       = 1000  // 10.00 in hundredths: the GitHub bonus
	maxRank         = 100000
)

// isComputedAt accepts a UTC date ("2026-10-13") or a UTC RFC 3339 time
// without fraction ("2026-10-13T09:00:00Z").
func isComputedAt(s string) bool {
	for _, layout := range []string{"2006-01-02", "2006-01-02T15:04:05Z"} {
		if len(s) != len(layout) {
			continue
		}
		t, err := time.Parse(layout, s)
		if err == nil && t.Format(layout) == s {
			return true
		}
	}
	return false
}

func isSHA256Hex(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// parseArenas splits a comma-separated list of 1 to 16 distinct names made
// of [a-z0-9_-], each 1 to 32 bytes.
func parseArenas(s string) []string {
	names := strings.Split(s, ",")
	if len(names) > maxArenas {
		panic("validator_scores: too many arenas")
	}
	seen := map[string]bool{}
	for _, name := range names {
		if name == "" || len(name) > maxArenaName {
			panic("validator_scores: invalid arena name")
		}
		for i := 0; i < len(name); i++ {
			c := name[i]
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
				panic("validator_scores: invalid arena name")
			}
		}
		if seen[name] {
			panic("validator_scores: duplicate arena " + name)
		}
		seen[name] = true
	}
	return names
}

// isMoniker rejects empty or oversized monikers, invalid UTF-8, ASCII and C1
// control characters (U+0000-U+001F, U+007F, U+0080-U+009F), bidirectional
// control characters (U+202A-U+202E, U+2066-U+2069), surrounding spaces, and
// the separator and contact characters '|' and '@'. Zero-width and
// directional marks (U+200B-U+200F) stay allowed: emoji monikers use U+200D.
func isMoniker(s string) bool {
	if s == "" || len(s) > maxMonikerBytes || !utf8.ValidString(s) || strings.TrimSpace(s) != s {
		return false
	}
	for _, r := range s {
		if r < 0x20 || (r >= 0x7f && r <= 0x9f) || r == '|' || r == '@' ||
			(r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) {
			return false
		}
	}
	return true
}

// parseNat parses a canonical non-negative decimal (no sign, no leading
// zero) not above max.
func parseNat(s string, max int) (int, bool) {
	if s == "" || len(s) > 7 || (len(s) > 1 && s[0] == '0') {
		return 0, false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.Atoi(s)
	if err != nil || n > max {
		return 0, false
	}
	return n, true
}

func lineError(n int, msg string) string {
	return "validator_scores: line " + strconv.Itoa(n) + ": " + msg
}

// checkLine validates "operator|moniker|total|rank|github|s1,...,sN" and
// returns the operator. Every number must be canonical, so a stored line
// can be copied into JSON as is.
func checkLine(line string, arenaCount, n int) string {
	f := strings.Split(line, "|")
	if len(f) != 6 {
		panic(lineError(n, "expected 6 fields"))
	}
	if !isCanonicalAddress(f[0]) {
		panic(lineError(n, "invalid operator"))
	}
	if !isMoniker(f[1]) {
		panic(lineError(n, "invalid moniker"))
	}
	if _, ok := parseNat(f[2], maxScore); !ok {
		panic(lineError(n, "invalid total"))
	}
	if rank, ok := parseNat(f[3], maxRank); !ok || rank < 1 {
		panic(lineError(n, "invalid rank"))
	}
	if _, ok := parseNat(f[4], maxGithub); !ok {
		panic(lineError(n, "invalid github"))
	}
	scores := strings.Split(f[5], ",")
	if len(scores) != arenaCount {
		panic(lineError(n, "arena count mismatch"))
	}
	for _, v := range scores {
		if _, ok := parseNat(v, maxScore); !ok {
			panic(lineError(n, "invalid arena score"))
		}
	}
	return f[0]
}
