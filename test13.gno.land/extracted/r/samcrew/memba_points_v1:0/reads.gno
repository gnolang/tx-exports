package memba_points_v1

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// ── Read getters (pure, non-failing; served via vm/qeval) ────────────────────────

// TotalPoints returns the sum of all current points across every account (O(1)).
func TotalPoints() int64 { return totalPoints }

// HolderCount returns the number of accounts with a positive balance (O(1)).
func HolderCount() int { return holderCount }

// GetOwner returns the current owner (multisig, or a DAO executor after handoff).
func GetOwner() address { return owner }

// IsPaused reports whether Award/Revoke are frozen.
func IsPaused() bool { return paused }

// BalanceJSON returns one account's balance (incl. its on-chain tier) as JSON, or the zero record if
// the address is unknown. Tier is canonical here — read from the on-chain band ladder — so consumers
// must NOT re-derive it client-side (see ProfileJSON for points+tier+rank in one call).
func BalanceJSON(addr string) string {
	pts, upd := int64(0), int64(0)
	if v, ok := accounts.Get(addr); ok {
		a := v.(*Account)
		pts, upd = a.Points, a.UpdatedAt
	}
	return ufmt.Sprintf(`{"addr":"%s","points":%d,"tier":"%s","updatedAt":%d}`,
		jsonEscape(addr), pts, jsonEscape(tierFor(pts)), upd)
}

// GetAwardersJSON returns the whitelisted awarder realm pkgpaths as a JSON string array (bounded —
// the whitelist is small + owner-managed). Public "who may mint points" transparency.
func GetAwardersJSON() string {
	var sb strings.Builder
	sb.WriteString("[")
	first := true
	awarders.Iterate("", "", func(k string, _ any) bool {
		if !first {
			sb.WriteString(",")
		}
		first = false
		sb.WriteString(`"`)
		sb.WriteString(jsonEscape(k))
		sb.WriteString(`"`)
		return false
	})
	sb.WriteString("]")
	return sb.String()
}

// jsonEscape escapes a string for embedding in a JSON string literal. Addresses are bech32 and
// awarder keys are pkgpaths, but the read path escapes defensively regardless.
func jsonEscape(s string) string {
	var sb strings.Builder
	for _, r := range s {
		switch r {
		case '"':
			sb.WriteString("\\\"")
		case '\\':
			sb.WriteString("\\\\")
		case '\n':
			sb.WriteString("\\n")
		case '\r':
			sb.WriteString("\\r")
		case '\t':
			sb.WriteString("\\t")
		default:
			if r < 0x20 {
				sb.WriteString(ufmt.Sprintf("\\u%04x", r))
			} else {
				sb.WriteString(string(r))
			}
		}
	}
	return sb.String()
}
