package dao

import (
	"strings"

	"gno.land/p/demo/ufmt"
)

// EscapeHTML escapes special characters like "<" to become "&lt;".
// It escapes only five such characters: <, >, &, ' and ".
func EscapeHTML(s string) string {
	s = strings.ReplaceAll(s, `&`, "&amp;")
	s = strings.ReplaceAll(s, `"`, "&#34;")
	s = strings.ReplaceAll(s, `'`, "&#39;")
	s = strings.ReplaceAll(s, `<`, "&lt;")
	return strings.ReplaceAll(s, `>`, "&gt;")
}

// NewLink creates a new Markdown link.
func NewLink(text, uri string) string {
	return ufmt.Sprintf("[%s](%s)", text, uri)
}

// NewLinkURI creates a new Markdown link where text and URI are the same.
func NewLinkURI(uri string) string {
	return ufmt.Sprintf("[%s](%s)", uri, uri)
}
