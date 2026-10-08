// Package svg draws the small on-chain SVGs of GnoRadio (covers, tickets,
// charts) with a strings.Builder, which keeps vm/qrender gas low.
package svg

import (
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

type Canvas struct{ b strings.Builder }

// New opens a w×h SVG whose <style> holds css.
func New(w, h int, css string) *Canvas {
	c := &Canvas{}
	c.b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="` + itoa(w) + `" height="` + itoa(h) +
		`" viewBox="0 0 ` + itoa(w) + ` ` + itoa(h) + `"><style>` + css + `</style>`)
	return c
}

func (c *Canvas) Raw(s string) { c.b.WriteString(s) }

// Rect draws a rectangle; extra holds more attributes, e.g. ` mask="url(#h)"`.
func (c *Canvas) Rect(x, y, w, h, rx int, fill, extra string) {
	c.b.WriteString(`<rect x="` + itoa(x) + `" y="` + itoa(y) + `" width="` + itoa(w) + `" height="` + itoa(h) +
		`" rx="` + itoa(rx) + `" fill="` + fill + `"` + extra + `/>`)
}

func (c *Canvas) Circle(cx, cy, r int, fill string) {
	c.b.WriteString(`<circle cx="` + itoa(cx) + `" cy="` + itoa(cy) + `" r="` + itoa(r) + `" fill="` + fill + `"/>`)
}

// Text writes s escaped; attrs follows font-size, e.g. ` text-anchor="end" class="m"`.
func (c *Canvas) Text(x, y int, s, fill string, size int, attrs string) {
	c.b.WriteString(`<text x="` + itoa(x) + `" y="` + itoa(y) + `" fill="` + fill + `" font-size="` + itoa(size) +
		`"` + attrs + `>` + Escape(s) + `</text>`)
}

// Data closes the SVG and returns it as a base64 data URI.
func (c *Canvas) Data() string {
	c.b.WriteString("</svg>")
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(c.b.String()))
}

// Image closes the SVG and returns it as a markdown image.
func (c *Canvas) Image(alt string) string {
	return "![" + sanitize.InlineText(alt) + "](" + c.Data() + ")"
}

// Escape makes text safe inside SVG: titles and names may hold '&'.
func Escape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	return strings.ReplaceAll(s, ">", "&gt;")
}

// Clip shortens s to n runes, ending with an ellipsis.
func Clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

// FNV is the 32-bit FNV-1a hash, used to pick a composition from a title.
func FNV(s string) uint32 {
	h := uint32(2166136261)
	for i := 0; i < len(s); i++ {
		h ^= uint32(s[i])
		h *= 16777619
	}
	return h
}

func itoa(n int) string { return strconv.Itoa(n) }
