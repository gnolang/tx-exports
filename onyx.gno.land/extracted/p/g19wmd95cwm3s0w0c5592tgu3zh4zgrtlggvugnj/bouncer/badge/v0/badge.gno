// Package badge builds small flat SVG badges ("label | message") and turns
// them into data: URIs and Markdown images that gnoweb renders inline.
//
// It is pure: no state, no realm imports. Text is XML-escaped and capped,
// and colors come from a fixed palette, so any input gives a well-formed,
// bounded SVG.
package badge

import (
	"encoding/base64"
	"strconv"
	"strings"
)

// Colors a badge message can use.
const (
	Green  = "green"
	Orange = "orange"
	Red    = "red"
	Grey   = "grey"
)

var palette = map[string]string{
	Green:  "#2e7d32",
	Orange: "#c25e00",
	Red:    "#c62828",
	Grey:   "#616161",
}

const (
	labelColor = "#333333"
	maxText    = 40  // runes, per side
	maxAlt     = 120 // runes of alt text
	charWidth  = 7   // px per character at 11px Verdana, rounded up
	padding    = 8   // px either side of each text
	height     = 20
)

// SVG returns a badge with label on the left and message on the right, the
// message on color (one of the palette names; anything else is Grey).
func SVG(label, message, color string) string {
	label, message = clip(label), clip(message)
	fill, ok := palette[color]
	if !ok {
		fill = palette[Grey]
	}
	lw := textWidth(label) + 2*padding
	mw := textWidth(message) + 2*padding
	w := lw + mw
	title := escape(label + ": " + message)

	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="` + itoa(w) + `" height="` + itoa(height) + `" role="img" aria-label="` + title + `">`)
	b.WriteString(`<title>` + title + `</title>`)
	b.WriteString(`<rect width="` + itoa(lw) + `" height="` + itoa(height) + `" rx="3" fill="` + labelColor + `"/>`)
	b.WriteString(`<rect x="` + itoa(lw) + `" width="` + itoa(mw) + `" height="` + itoa(height) + `" rx="3" fill="` + fill + `"/>`)
	// Square off the inner corners where the halves meet.
	b.WriteString(`<rect x="` + itoa(lw-3) + `" width="6" height="` + itoa(height) + `" fill="` + fill + `"/>`)
	b.WriteString(`<rect x="` + itoa(lw-3) + `" width="3" height="` + itoa(height) + `" fill="` + labelColor + `"/>`)
	b.WriteString(`<g fill="#ffffff" font-family="Verdana,DejaVu Sans,sans-serif" font-size="11" text-anchor="middle">`)
	b.WriteString(`<text x="` + itoa(lw/2) + `" y="14">` + escape(label) + `</text>`)
	b.WriteString(`<text x="` + itoa(lw+mw/2) + `" y="14">` + escape(message) + `</text>`)
	b.WriteString(`</g></svg>`)
	return b.String()
}

// DataURI returns svg as a base64 data:image/svg+xml URI.
func DataURI(svg string) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
}

// Markdown returns a Markdown image of svg with alt text alt. If link is
// not empty, the image links there. link must already be a safe URL.
func Markdown(alt, svg, link string) string {
	img := "![" + escapeAlt(clipN(alt, maxAlt)) + "](" + DataURI(svg) + ")"
	if link == "" {
		return img
	}
	return "[" + img + "](" + link + ")"
}

// clip keeps the first maxText runes of s, with control characters dropped.
func clip(s string) string { return clipN(s, maxText) }

// clipN keeps the first max runes of s, with control characters dropped.
func clipN(s string, max int) string {
	var b strings.Builder
	n := 0
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			continue
		}
		if n == max {
			break
		}
		b.WriteRune(r)
		n++
	}
	return b.String()
}

func textWidth(s string) int {
	return len([]rune(s)) * charWidth
}

func escape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&#39;").Replace(s)
}

// escapeAlt keeps alt text from closing the Markdown image early.
func escapeAlt(s string) string {
	return strings.NewReplacer(`\`, `\\`, "[", `\[`, "]", `\]`).Replace(s)
}

func itoa(n int) string { return strconv.Itoa(n) }
