package questmaster

import (
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// Escaping. Every piece of user text that reaches a page (titles, details,
// reject reasons, work links) goes through one of the helpers below, which
// wrap p/nt/markdown/sanitize/v0 (the sanitizer that gnoweb's own markdown
// tests are written against) plus the gnoweb-specific steps described below.
//
// Nothing a user types can produce a heading, list, table cell break, new
// table row, link, image, HTML tag, mention link or math:
//   - esc:       single-line slots (headings, link text). Folds line breaks to
//     spaces and backslash-escapes Markdown punctuation and `<`, `&`.
//   - escCell:   table cells. As esc, plus `|` and tabs.
//   - escBlock:  multi-line text (details, reasons). A blockquote that keeps
//     line breaks; every line is escaped like a table cell.
//   - linkOrText: the work link. Clickable only when it passes sanitize.URL
//     (http/https only; ( ) < > ` | and other unsafe bytes percent-encoded)
//     and nothing unsafe is left in the target; otherwise plain text. Its
//     visible text is always the escaped URL itself, never user-chosen text.
//
// gnoweb adds two extensions the sanitizer does not know about, so every
// helper also runs gnowebSafe on its output:
//   - "@name" and " g1…" (an address after a space) become profile links.
//     "@" becomes "\@" (a Markdown escape that renders as "@"), the space
//     before "g1" becomes the entity "&#32;", and a "g1" at the very start of
//     the text becomes "&#103;1", because the realm itself often puts a space
//     right before user text ("# Quest 1: ", "| ", "> ").
//   - "$…$" and "$$…$$" become math. Every "$" becomes "\$".
// Each renders as the plain character in gnoweb; checked in the real renderer
// by scripts/local-flow.sh.

func esc(s string) string     { return gnowebSafe(sanitize.InlineText(s)) }
func escCell(s string) string { return gnowebSafe(sanitize.TableCell(s)) }

// escBlock shows multi-line user text as a blockquote that keeps its line
// breaks but nothing else: every line is escaped like a table cell (so no
// link, image, HTML, `|` table or line-leading marker survives), a leading
// "=" is escaped (no setext heading), and lines end with a hard break.
func escBlock(s string) string {
	s = sanitize.NormalizeBreaks(sanitize.StripBidiAndZeroWidth(s))
	s = strings.ReplaceAll(s, "\u2028", "\n")
	s = strings.ReplaceAll(s, "\u2029", "\n")
	s = strings.ReplaceAll(s, "\u0085", "\n")
	var b strings.Builder
	blank := true // suppress leading and repeated blank lines
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			if !blank {
				b.WriteString(">\n")
			}
			blank = true
			continue
		}
		line = escCell(line)
		if strings.HasPrefix(line, "=") {
			line = "\\" + line
		}
		b.WriteString("> " + line + "  \n")
		blank = false
	}
	out := strings.TrimSuffix(b.String(), ">\n")
	if out == "" {
		return ""
	}
	return "\n" + out + "\n"
}

// gnowebSafe applies the gnoweb-specific steps described above.
func gnowebSafe(s string) string {
	s = strings.ReplaceAll(s, "@", `\@`)
	s = strings.ReplaceAll(s, "$", `\$`)
	s = strings.ReplaceAll(s, " g1", "&#32;g1")
	if strings.HasPrefix(s, "g1") {
		s = "&#103;1" + s[2:]
	}
	return s
}

// linkOrText shows a work link. The escrow already guarantees it starts
// with https:// and has no spaces or control characters.
func linkOrText(link string) string {
	text := escCell(link)
	u := sanitize.URL(link)
	if u == "" || strings.ContainsAny(u, "()<>[]| \"'`") {
		return text
	}
	return "[" + text + "](" + u + ")"
}
