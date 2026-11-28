// escape.gno — centralized sanitization (design §7 T9).
//
// EVERY caller-supplied string that reaches Render goes through one
// of the helpers below, in exactly ONE place per slot, before it is
// concatenated into Markdown. No Render code formats a raw user
// string. Wrap each string exactly once: the sanitize helpers are
// NOT idempotent (a second pass re-escapes the backslashes the first
// pass added).
//
// Slot rules (from gno.land/p/nt/markdown/sanitize/v0):
//   - Headings, link text, key-value rows: escInline
//     (sanitize.InlineText — escapes # [ ] ( ) < & * _ ` ~ > and
//     folds newlines to spaces, so a payload can never open a
//     heading, a link, or an HTML tag).
//   - Table cells: escCell (sanitize.TableCell = InlineText plus
//     "|" -> "\|"; InlineText alone does NOT escape pipes, so a
//     table cell must never use escInline).
//   - Multi-paragraph prose: escBlock (sanitize.Block — headings,
//     lists, blockquotes, setext underlines, table rows and
//     line-leading <script> are escaped; NOTE: inline links are
//     preserved by design, so escBlock is NOT used for any Render
//     slot where a live link must stay dead — Render shows the bounty
//     scope through escCell instead).
//   - Link hrefs: escURL (sanitize.URL — allowlist http/https and
//     relative URLs; javascript:/data:/etc. become "", and the
//     caller must then render plain text instead of a link).
//   - Addresses from a URL path: escAddr validates the bech32
//     "g1..." shape (sanitize.BechString); an invalid address is
//     "" and the router renders "not found".
package bugtavern

import (
	"strconv"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// escInline sanitizes a user string for an inline Markdown slot
// (heading, link text, key-value row).
func escInline(s string) string {
	return sanitize.InlineText(s)
}

// escBlock sanitizes multi-paragraph user prose for a block Markdown
// slot. Inline links survive by design (see the file header); do not
// use it where a live link must stay dead.
func escBlock(s string) string {
	return sanitize.Block(s)
}

// escCell sanitizes a user string for a Markdown table cell.
func escCell(s string) string {
	return sanitize.TableCell(s)
}

// escURL validates a user URL for a link href. It returns "" when the
// URL is empty or its scheme is not allowed (javascript:, data:,
// protocol-relative //host, ...); callers render plain text then.
func escURL(s string) string {
	return sanitize.URL(s)
}

// escAddr validates a "g1..." address string from a URL path. It
// returns "" when the string is not a valid bech32 address.
// (BechString takes the HRP "g" — the "1" separator is implied.)
func escAddr(s string) string {
	return sanitize.BechString(s, "g")
}

// shortAddr shortens a validated address for display
// ("g1abc…xyz": first 6 chars, last 4). Addresses are chain-issued,
// never free text, so no Markdown escaping is needed on the output.
func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:6] + "…" + s[len(s)-4:]
}

// fmtGNOT renders an ugnot amount as GNOT with up to 6 decimals and
// no trailing zeros ("5000000" -> "5", "4500000" -> "4.5").
func fmtGNOT(amount int64) string {
	if amount == 0 {
		return "0"
	}
	neg := amount < 0
	if neg {
		amount = -amount
	}
	whole := amount / 1000000
	frac := amount % 1000000
	out := strconv.FormatInt(whole, 10)
	if frac != 0 {
		digits := strconv.FormatInt(frac, 10)
		for len(digits) < 6 {
			digits = "0" + digits
		}
		for len(digits) > 0 && digits[len(digits)-1] == '0' {
			digits = digits[:len(digits)-1]
		}
		out += "." + digits
	}
	if neg {
		return "-" + out
	}
	return out
}
