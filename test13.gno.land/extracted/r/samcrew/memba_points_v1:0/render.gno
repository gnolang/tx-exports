package memba_points_v1

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// Render — human gnoweb view. "" → home (totals + owner + awarders); "a/<addr>" → one balance.
func Render(path string) string {
	if path == "" {
		return ufmt.Sprintf(
			"# Memba Points (MP)\n\nSoulbound, non-transferable reputation points.\n\n"+
				"- Holders: **%d**\n- Total points: **%d**\n- Paused: **%t**\n- Owner: `%s`\n- Awarders: %s\n",
			holderCount, totalPoints, paused, owner.String(), renderAwarders())
	}
	if strings.HasPrefix(path, "a/") {
		addr := strings.TrimPrefix(path, "a/")
		pts := GetPoints(addr) // raw addr for the lookup; the displayed value is sanitized
		return ufmt.Sprintf("# Points for `%s`\n\n**%d** MP · Tier: %s\n",
			mdInlineEscape(addr), pts, mdInlineEscape(tierFor(pts)))
	}
	return "# 404\n"
}

// mdInlineEscape drops markdown-significant characters from path-derived / untrusted values before
// writing them into Render output, preventing markdown/code-span injection (gno contract-review #10).
// Well-formed bech32 addresses and tier names contain none of these, so this is loss-free in practice.
func mdInlineEscape(s string) string {
	var sb strings.Builder
	for _, r := range s {
		switch r {
		case '`', '|', '<', '>', '\n', '\r', '\t', '*', '_', '[', ']', '#':
			// drop markdown-significant runes
		default:
			sb.WriteString(string(r))
		}
	}
	return sb.String()
}

func renderAwarders() string {
	var sb strings.Builder
	first := true
	awarders.Iterate("", "", func(k string, _ any) bool {
		if !first {
			sb.WriteString(", ")
		}
		first = false
		sb.WriteString("`")
		sb.WriteString(mdInlineEscape(k)) // awarder pkgpath is owner-set but still escaped (checklist #10)
		sb.WriteString("`")
		return false
	})
	if first {
		return "_none_"
	}
	return sb.String()
}
