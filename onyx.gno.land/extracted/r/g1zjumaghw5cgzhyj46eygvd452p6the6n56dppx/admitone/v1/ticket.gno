package admitone

import (
	"encoding/base64"
	"strconv"
	"strings"
	"time"
)

// ticketSVG draws a ticket as a Markdown image (an SVG data URI, which gnoweb
// allows). The stamp across it is what whoever checks the door looks at.
func ticketSVG(t *ticket, now int64) string {
	e := t.ev
	paper, ink, accent := "#fff4d6", "#3b2a1a", "#c8372d"
	stamp, stampColor := "", ""
	switch {
	case t.admittedAt != 0:
		stamp, stampColor = "ADMITTED", "#1f8f4e"
	case e.cancelled:
		stamp, stampColor = "CANCELLED", "#b3261e"
	case now >= e.end:
		stamp, stampColor = "UNUSED", "#6b6b6b"
	case t.listed:
		stamp, stampColor = "FOR RESALE", "#1f6fb5"
	}
	if stamp != "" {
		paper = "#f3ead2"
	}

	var s strings.Builder
	s.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="640" height="300" viewBox="0 0 640 300" font-family="Georgia, serif">`)
	// Body and stub, with the notches of a ticket meant to be torn.
	s.WriteString(`<path d="M12 12 H628 V130 A20 20 0 0 0 628 170 V288 H12 V170 A20 20 0 0 0 12 130 Z" fill="` + paper + `" stroke="` + ink + `" stroke-width="3"/>`)
	s.WriteString(`<line x1="480" y1="22" x2="480" y2="278" stroke="` + ink + `" stroke-width="2" stroke-dasharray="6 6"/>`)
	s.WriteString(`<rect x="28" y="28" width="436" height="244" fill="none" stroke="` + accent + `" stroke-width="2"/>`)
	s.WriteString(text(246, 76, 40, accent, "bold", "ADMIT ONE"))
	s.WriteString(text(246, 116, 22, ink, "bold", clip(e.name, 30)))
	s.WriteString(text(246, 146, 16, ink, "normal", time.Unix(e.start, 0).UTC().Format("Mon 2 Jan 2006, 15:04 UTC")))
	s.WriteString(text(246, 174, 15, ink, "normal", priceLabel(e.price)+" · ticket "+t.id))
	if stamp != "" {
		// The stamp has a row of its own, so it never hides what is printed.
		s.WriteString(`<g transform="rotate(-5 246 228)">`)
		s.WriteString(`<rect x="106" y="200" width="280" height="56" rx="8" fill="none" stroke="` + stampColor + `" stroke-width="5"/>`)
		s.WriteString(text(246, 240, 32, stampColor, "bold", stamp))
		s.WriteString(`</g>`)
	} else {
		s.WriteString(text(246, 236, 14, ink, "italic", "show this ticket at the door"))
	}
	// The stub.
	s.WriteString(text(556, 104, 14, ink, "normal", "No."))
	s.WriteString(text(556, 162, 50, accent, "bold", strconv.Itoa(t.serial)))
	s.WriteString(text(556, 204, 12, ink, "normal", "of "+strconv.Itoa(e.capacity)))
	s.WriteString(`</svg>`)
	return "![Ticket " + t.id + "](data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(s.String())) + ")"
}

func text(x, y, size int, fill, weight, body string) string {
	return `<text x="` + strconv.Itoa(x) + `" y="` + strconv.Itoa(y) + `" font-size="` + strconv.Itoa(size) +
		`" font-weight="` + weight + `" fill="` + fill + `" text-anchor="middle">` + xmlEscape(body) + `</text>`
}

// clip shortens s to at most n runes, adding an ellipsis.
func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}

func xmlEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '&':
			b.WriteString("&amp;")
		case '<':
			b.WriteString("&lt;")
		case '>':
			b.WriteString("&gt;")
		case '"':
			b.WriteString("&quot;")
		case '\'':
			b.WriteString("&apos;")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}
