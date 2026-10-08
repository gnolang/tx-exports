// Package render is the Remix Lab rendering block: escaping for untrusted
// text, Markdown tables, paginated lists, route parsing and gnoweb
// transaction links.
//
// Every string that came from a user must pass through Text or Paragraph
// before it reaches Markdown. Escaped output cannot open links, images,
// HTML, headings, tables, code spans, bare URLs or @mentions. (gnoweb still
// links a bare g1 address; that target is a first-party user page.)
// Invisible and direction-changing format characters are dropped.
package render

import (
	"net/url"
	"strconv"
	"strings"
)

// Text escapes s for inline Markdown. Newlines and control characters become
// spaces, invisible and direction-changing format characters are dropped,
// every ASCII punctuation character Markdown or gnoweb could interpret is
// backslash-escaped, and "<", ">" and "&" become entities.
func Text(s string) string {
	var sb strings.Builder
	for _, r := range s {
		switch {
		case isHiddenFormat(r):
			// dropped
		case r == '<':
			sb.WriteString("&lt;")
		case r == '>':
			sb.WriteString("&gt;")
		case r == '&':
			sb.WriteString("&amp;")
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == 0x2028 || r == 0x2029:
			sb.WriteByte(' ')
		case r < 0x80 && isMarkdownPunct(byte(r)):
			sb.WriteByte('\\')
			sb.WriteRune(r)
		default:
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

// Paragraph escapes multi-line text, keeping line breaks as hard breaks.
// Leading indentation is removed so no line becomes a code block.
func Paragraph(s string) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = Text(strings.TrimLeft(l, " \t"))
	}
	return strings.Join(lines, "  \n")
}

// Code renders s as an inline code span that cannot be closed early. Control
// characters become spaces, format characters are dropped, and "|" becomes
// "¦" so the span is also safe inside a table cell.
func Code(s string) string {
	s = strings.Map(func(r rune) rune {
		switch {
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == 0x2028 || r == 0x2029:
			return ' '
		case isHiddenFormat(r):
			return -1
		case r == '|':
			return '¦'
		}
		return r
	}, s)
	fence := "`"
	for strings.Contains(s, fence) {
		fence += "`"
	}
	return fence + " " + s + " " + fence
}

func isMarkdownPunct(c byte) bool {
	return strings.IndexByte("\\`*_{}[]()#+-.!|~:\"'=$%^/@", c) >= 0
}

// isHiddenFormat matches core.IsHiddenFormat: invisible or
// direction-changing format characters (ZWNJ and ZWJ are kept).
func isHiddenFormat(r rune) bool {
	switch {
	case r == 0x00ad, r == 0x061c, r == 0x180e, r == 0x200b, r == 0x200e, r == 0x200f, r == 0xfeff:
		return true
	case r >= 0x202a && r <= 0x202e:
		return true
	case r >= 0x2060 && r <= 0x206f:
		return true
	case r >= 0xfff9 && r <= 0xfffb:
		return true
	}
	return false
}

// Heading returns a Markdown heading with escaped text. level is clamped to
// 1..6.
func Heading(level int, text string) string {
	if level < 1 {
		level = 1
	}
	if level > 6 {
		level = 6
	}
	return strings.Repeat("#", level) + " " + Text(text) + "\n\n"
}

// Table renders a Markdown table. Headers are escaped with Text. Row cells
// are NOT escaped: build rows with Row (untrusted text) or TrustedRow
// (markup from Link, TxLink, Code). As a last line of defence every cell has
// line breaks replaced and unescaped "|" escaped, so a cell can never split
// the row or end the table. Rows shorter than the header are padded; longer
// rows are truncated.
func Table(headers []string, rows [][]string) string {
	if len(headers) == 0 {
		return ""
	}
	var sb strings.Builder
	sb.WriteString("|")
	for _, h := range headers {
		sb.WriteString(" " + Text(h) + " |")
	}
	sb.WriteString("\n|")
	for range headers {
		sb.WriteString(" --- |")
	}
	sb.WriteString("\n")
	for _, row := range rows {
		sb.WriteString("|")
		for i := range headers {
			cell := ""
			if i < len(row) {
				cell = tableCell(row[i])
			}
			sb.WriteString(" " + cell + " |")
		}
		sb.WriteString("\n")
	}
	return sb.String() + "\n"
}

// tableCell keeps a cell on one line and inside its column.
func tableCell(c string) string {
	var sb strings.Builder
	backslashes := 0
	for _, r := range c {
		switch {
		case r == '\n' || r == '\r' || r == 0x85 || r == 0x2028 || r == 0x2029:
			sb.WriteByte(' ')
		case r == '|' && backslashes%2 == 0:
			sb.WriteString("\\|")
		default:
			sb.WriteRune(r)
		}
		if r == '\\' {
			backslashes++
		} else {
			backslashes = 0
		}
	}
	return sb.String()
}

// TrustedRow marks a row whose cells were already built from escaped text
// and trusted markup (for example links from Link or TxLink). Use Row for
// untrusted cells.
func TrustedRow(cells ...string) []string { return cells }

// Row escapes every cell.
func Row(cells ...string) []string {
	out := make([]string, len(cells))
	for i, c := range cells {
		out[i] = Text(c)
	}
	return out
}

// Link renders a link with an escaped label to a realm-relative target,
// e.g. "/r/foo/bar:polls/3". External or scheme-bearing targets are refused
// and rendered as plain escaped text.
func Link(label, target string) string {
	if !isRelativeRealmTarget(target) {
		return Text(label)
	}
	return "[" + Text(label) + "](" + target + ")"
}

// RealmURL turns a package path into the realm-relative URL gnoweb serves,
// optionally with a render path: RealmURL("gno.land/r/a/b", "polls/1") ->
// "/r/a/b:polls/1".
func RealmURL(pkgPath, renderPath string) string {
	base, ok := relativeRealm(pkgPath)
	if !ok {
		return ""
	}
	if renderPath == "" {
		return base
	}
	return base + ":" + escapePath(renderPath)
}

// RealmQueryURL is RealmURL with query parameters: keys must be Go
// identifiers and values are URL-encoded, so any value (including "&", "="
// or "%") reaches Render intact through ParsePath. route itself must not
// contain "?". It returns "" on invalid input.
func RealmQueryURL(pkgPath, route string, kv ...string) string {
	if strings.IndexByte(route, '?') >= 0 || len(kv)%2 != 0 {
		return ""
	}
	u := RealmURL(pkgPath, route)
	if u == "" {
		return ""
	}
	if route == "" {
		u += ":"
	}
	for i := 0; i < len(kv); i += 2 {
		if !isIdent(kv[i]) {
			return ""
		}
		sep := "&"
		if i == 0 {
			sep = "?"
		}
		u += sep + kv[i] + "=" + url.QueryEscape(kv[i+1])
	}
	return u
}

// TxLink renders a gnoweb transaction link for fn on the realm at pkgPath
// with the given key/value arguments. Function and key names must be Go
// identifiers; values are URL-encoded. Invalid input renders the label as
// plain text so a bad link never reaches the page.
func TxLink(label, pkgPath, fn string, kv ...string) string {
	u := TxURL(pkgPath, fn, kv...)
	if u == "" {
		return Text(label)
	}
	return "[" + Text(label) + "](" + u + ")"
}

// TxURL builds the gnoweb "$help" URL used by TxLink, or "" when the input
// is invalid.
func TxURL(pkgPath, fn string, kv ...string) string {
	base, ok := relativeRealm(pkgPath)
	if !ok || !isIdent(fn) || len(kv)%2 != 0 {
		return ""
	}
	u := base + "$help&func=" + fn
	for i := 0; i < len(kv); i += 2 {
		if !isIdent(kv[i]) {
			return ""
		}
		u += "&" + kv[i] + "=" + url.QueryEscape(kv[i+1])
	}
	return u
}

// ParsePath splits a render path such as "polls/3?page=2" into its route
// segments and query values. Malformed queries yield empty values.
func ParsePath(path string) ([]string, url.Values) {
	route, rawQuery := path, ""
	if i := strings.IndexByte(path, '?'); i >= 0 {
		route, rawQuery = path[:i], path[i+1:]
	}
	var segs []string
	for _, s := range strings.Split(route, "/") {
		if s != "" {
			segs = append(segs, s)
		}
	}
	q, err := url.ParseQuery(rawQuery)
	if err != nil {
		q = url.Values{}
	}
	return segs, q
}

// Page reads a 1-based "page" query value, clamped to 1..maxPage (a maxPage
// below 1 counts as 1).
func Page(q url.Values, maxPage int) int {
	if maxPage < 1 {
		maxPage = 1
	}
	p, err := strconv.Atoi(q.Get("page"))
	if err != nil || p < 1 {
		return 1
	}
	if p > maxPage {
		return maxPage
	}
	return p
}

// PageCount returns the number of pages needed for total items.
func PageCount(total, pageSize int) int {
	if total <= 0 || pageSize <= 0 {
		return 1
	}
	return (total + pageSize - 1) / pageSize
}

// Pager renders previous/next links for a paginated route under pkgPath.
// page is clamped to 1..pages.
func Pager(pkgPath, route string, page, pages int) string {
	if pages <= 1 {
		return ""
	}
	if page < 1 {
		page = 1
	}
	if page > pages {
		page = pages
	}
	var parts []string
	if page > 1 {
		parts = append(parts, Link("← previous", RealmQueryURL(pkgPath, route, "page", strconv.Itoa(page-1))))
	}
	parts = append(parts, "page "+strconv.Itoa(page)+" of "+strconv.Itoa(pages))
	if page < pages {
		parts = append(parts, Link("next →", RealmQueryURL(pkgPath, route, "page", strconv.Itoa(page+1))))
	}
	return strings.Join(parts, " · ") + "\n\n"
}

// relativeRealm maps "gno.land/r/..." to "/r/...". Every path segment must
// be non-empty and use only lowercase letters, digits, "_" and "-".
func relativeRealm(pkgPath string) (string, bool) {
	const prefix = "gno.land/r/"
	if !strings.HasPrefix(pkgPath, prefix) || len(pkgPath) > 256 {
		return "", false
	}
	for _, seg := range strings.Split(pkgPath[len(prefix):], "/") {
		if seg == "" {
			return "", false
		}
		for _, c := range seg {
			lower := c >= 'a' && c <= 'z'
			digit := c >= '0' && c <= '9'
			if !(lower || digit || c == '_' || c == '-') {
				return "", false
			}
		}
	}
	return pkgPath[len("gno.land"):], true
}

func isRelativeRealmTarget(t string) bool {
	if !strings.HasPrefix(t, "/r/") && !strings.HasPrefix(t, "/p/") {
		return false
	}
	for _, c := range t {
		if c <= ' ' || c == '(' || c == ')' || c == '<' || c == '>' || c == '"' || c == '\\' || c == '`' {
			return false
		}
	}
	return !strings.Contains(t, "//")
}

// escapePath keeps a render path safe inside a Markdown link target.
func escapePath(p string) string {
	var sb strings.Builder
	for i := 0; i < len(p); i++ {
		c := p[i]
		safe := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			strings.IndexByte("/-_.?=&:", c) >= 0
		if safe {
			sb.WriteByte(c)
		} else {
			sb.WriteString("%" + strings.ToUpper(strconv.FormatInt(int64(c)>>4, 16)) + strings.ToUpper(strconv.FormatInt(int64(c)&15, 16)))
		}
	}
	return sb.String()
}

func isIdent(s string) bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for i, c := range s {
		letter := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
		digit := c >= '0' && c <= '9'
		if !(letter || (i > 0 && digit)) {
			return false
		}
	}
	return true
}
