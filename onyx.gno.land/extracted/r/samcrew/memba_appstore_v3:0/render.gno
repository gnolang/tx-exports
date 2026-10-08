package memba_appstore_v3

import (
	"chain/runtime"

	"gno.land/p/nt/ufmt/v0"
)

// RenderMaxRows bounds the Render() output so a large catalog can never make the
// realm render-DoS (mirrors the feed's live-only bounded render).
const RenderMaxRows = 100

// Render shows the live catalog (bounded) — a read-only trust surface for gnoweb.
// The frontend reads structured data via the getters, not this markdown.
func Render(path string) string {
	sb := ""
	sb += "# Memba App Store\n\n"
	sb += ufmt.Sprintf("Curated gno.land dApps. **Listing fee:** %d ugnot → treasury.\n\n", registrationFee)
	if paused {
		sb += "> ⏸️ Registration is paused.\n\n"
	}

	rows := 0
	live := 0
	sb += "| App | Package | Category |\n|---|---|---|\n"
	listings.Iterate("", "", func(_ string, v any) bool {
		l := v.(*Listing)
		// Curated gnoweb view: live (Verified) + un-flag-hidden only — never pending/rejected.
		if l.Status != StatusLive || l.FlagCount >= FlagHideThreshold {
			return false
		}
		live++
		if rows >= RenderMaxRows {
			return false // stop appending, keep counting via the header below
		}
		rows++
		sb += ufmt.Sprintf("| %s | `%s` | %s |\n", esc(l.Name), esc(l.PkgPath), esc(l.Category))
		return false
	})

	if live == 0 {
		sb += "\n*No live apps yet.*\n"
	} else {
		sb += ufmt.Sprintf("\n*%d live app(s)%s. Block %d.*\n", live, moreNote(live), runtime.ChainHeight())
	}
	return sb
}

func moreNote(live int) string {
	if live > RenderMaxRows {
		return ufmt.Sprintf(" (showing first %d)", RenderMaxRows)
	}
	return ""
}

// esc neutralizes the markdown/table metachars that could break the table or inject
// layout from an attacker-supplied listing field.
func esc(s string) string {
	out := ""
	for _, r := range s {
		switch r {
		case '|':
			out += "\\|"
		case '\n', '\r':
			out += " "
		case '`':
			out += "'"
		default:
			out += string(r)
		}
	}
	return out
}
