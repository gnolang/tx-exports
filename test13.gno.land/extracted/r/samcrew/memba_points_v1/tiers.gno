package memba_points_v1

import (
	"chain"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// Tier bands — an on-chain, owner-configurable ladder mapping points → a named status tier.
// Sorted ascending by MinPoints; the first band MUST have MinPoints == 0 so every holder has a tier.
// Tiers are canonical ON-CHAIN here (read via TierOf/TierBandsJSON), NOT re-derived client-side.

type Band struct {
	Name      string
	MinPoints int64
}

// MaxBands bounds SetTierBands parse cost + TierOf scan cost.
const MaxBands = 16

// tierBands is the live ladder. Defaults ship at init so tiers are live at launch; the owner tunes
// them via SetTierBands once the real points distribution is known — the defaults are PLACEHOLDERS,
// not frozen (SetTierBands replaces the whole ladder).
var tierBands = defaultBands()

func defaultBands() []Band {
	return []Band{
		{"Bronze", 0},
		{"Silver", 100},
		{"Gold", 500},
		{"Platinum", 2000},
		{"Diamond", 10000},
	}
}

// TierOf returns the tier name for an address's current points ("" if no bands are configured). Pure.
func TierOf(addr string) string { return tierFor(GetPoints(addr)) }

// tierFor returns the highest band whose MinPoints <= points (bands are ascending). O(bands).
func tierFor(points int64) string {
	name := ""
	for _, b := range tierBands {
		if points >= b.MinPoints {
			name = b.Name
		} else {
			break
		}
	}
	return name
}

// SetTierBands replaces the tier ladder. Owner only. spec is "Name:Min,Name:Min,..." with strictly
// ascending Min, the first Min == 0, 1..MaxBands entries, non-empty unique names. Emits TierBandsSet.
func SetTierBands(cur realm, spec string) {
	assertOwner(cur)
	bands := parseBands(spec) // panics on any invalid input
	tierBands = bands
	chain.Emit("TierBandsSet", "count", itoa64(int64(len(bands))))
}

func parseBands(spec string) []Band {
	if len(spec) == 0 || len(spec) > 512 {
		panic("tier spec empty or too long")
	}
	parts := strings.Split(spec, ",")
	if len(parts) < 1 || len(parts) > MaxBands {
		panic("tier band count out of range (1..MaxBands)")
	}
	bands := make([]Band, 0, len(parts))
	seen := make(map[string]bool)
	var prevMin int64
	for i, p := range parts {
		kv := strings.Split(p, ":")
		if len(kv) != 2 {
			panic("tier band must be Name:Min")
		}
		name := kv[0]
		if name == "" || seen[name] {
			panic("tier name empty or duplicate")
		}
		min, ok := parseNonNegInt(kv[1])
		if !ok {
			panic("tier MinPoints not a non-negative integer")
		}
		if i == 0 {
			if min != 0 {
				panic("first tier MinPoints must be 0")
			}
		} else if min <= prevMin {
			panic("tier MinPoints must be strictly ascending")
		}
		seen[name] = true
		bands = append(bands, Band{Name: name, MinPoints: min})
		prevMin = min
	}
	return bands
}

// parseNonNegInt parses a non-negative base-10 int64 (no strconv dep, overflow-guarded).
func parseNonNegInt(s string) (int64, bool) {
	if len(s) == 0 || len(s) > 19 {
		return 0, false
	}
	var n int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
		if n < 0 {
			return 0, false
		}
	}
	return n, true
}

// TierBandsJSON exposes the ladder: [{"name":"Bronze","minPoints":0},...]
func TierBandsJSON() string {
	var sb strings.Builder
	sb.WriteString("[")
	for i, b := range tierBands {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(ufmt.Sprintf(`{"name":"%s","minPoints":%d}`, jsonEscape(b.Name), b.MinPoints))
	}
	sb.WriteString("]")
	return sb.String()
}
