package arisan

import (
	"encoding/base64"
	"html"
	"math"
	"strconv"
	"strings"
)

// SlotState is the state of one member seat on the arisan wheel.
type SlotState int

const (
	SlotWaiting SlotState = iota // has not paid this round yet
	SlotPaid                     // paid this round, still waiting for a turn
	SlotWon                      // already received a pot in an earlier round
	SlotWinner                   // the member highlighted as latest winner
	SlotLate                     // has an unpaid debt (missed a round)
)

// Slot is one seat on the wheel. Label is drawn inside the seat (keep it to
// 1-3 characters, e.g. the join number); Caption is drawn under it.
type Slot struct {
	Label   string
	Caption string
	State   SlotState
}

type slotStyle struct{ fill, stroke, text string }

func styleOf(s SlotState) slotStyle {
	switch s {
	case SlotPaid:
		return slotStyle{"#2f9e6b", "#7ee2b0", "#ffffff"}
	case SlotWon:
		return slotStyle{"#8a6d1f", "#e8c25a", "#fff6d8"}
	case SlotWinner:
		return slotStyle{"#f2b632", "#fff1b8", "#3a2a00"}
	case SlotLate:
		return slotStyle{"#9e2f3c", "#f08a97", "#ffffff"}
	}
	return slotStyle{"#3a3330", "#8c7f77", "#e9e1da"}
}

// Wheel draws the circle as an SVG: one seat per member around a ring, with
// title (e.g. the pot) and subtitle (e.g. "Putaran 2 / 5") in the middle and a
// colour legend underneath. It returns raw SVG markup.
func Wheel(slots []Slot, title, subtitle string) string {
	const (
		w, h   = 420, 470
		cx, cy = 210, 215
		ring   = 150.0
		seatR  = 26
	)
	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="420" height="470" viewBox="0 0 420 470" font-family="Inter,Segoe UI,Helvetica,Arial,sans-serif">`)
	b.WriteString(`<defs><radialGradient id="bg" cx="50%" cy="45%" r="70%"><stop offset="0" stop-color="#3b2a20"/><stop offset="1" stop-color="#17110d"/></radialGradient>`)
	b.WriteString(`<radialGradient id="pot" cx="50%" cy="40%" r="60%"><stop offset="0" stop-color="#fbe3a1"/><stop offset="1" stop-color="#c8902a"/></radialGradient></defs>`)
	b.WriteString(`<rect x="0" y="0" width="420" height="470" rx="22" fill="url(#bg)"/>`)
	// ring
	b.WriteString(`<circle cx="210" cy="215" r="150" fill="none" stroke="#6b5444" stroke-width="2" stroke-dasharray="4 6"/>`)
	// pot in the middle
	b.WriteString(`<circle cx="210" cy="215" r="78" fill="url(#pot)" stroke="#fff1c4" stroke-width="3"/>`)
	b.WriteString(`<text x="210" y="208" text-anchor="middle" font-size="20" font-weight="700" fill="#3a2600">` + esc(clip(title, 16)) + `</text>`)
	b.WriteString(`<text x="210" y="234" text-anchor="middle" font-size="13" fill="#5a3d08">` + esc(clip(subtitle, 22)) + `</text>`)

	n := len(slots)
	for i, s := range slots {
		ang := -math.Pi/2 + 2*math.Pi*float64(i)/float64(max1(n))
		x := cx + int(math.Round(ring*math.Cos(ang)))
		y := cy + int(math.Round(ring*math.Sin(ang)))
		st := styleOf(s.State)
		if s.State == SlotWinner {
			b.WriteString(`<circle cx="` + itoa(x) + `" cy="` + itoa(y) + `" r="36" fill="#f2b632" opacity="0.28"/>`)
		}
		b.WriteString(`<circle cx="` + itoa(x) + `" cy="` + itoa(y) + `" r="` + itoa(seatR) + `" fill="` + st.fill + `" stroke="` + st.stroke + `" stroke-width="3"/>`)
		b.WriteString(`<text x="` + itoa(x) + `" y="` + itoa(y+6) + `" text-anchor="middle" font-size="17" font-weight="700" fill="` + st.text + `">` + esc(clip(s.Label, 3)) + `</text>`)
		if s.Caption != "" {
			ty := y + seatR + 15
			if y < cy-ring/2 {
				ty = y - seatR - 7 // top seats: caption above
			}
			b.WriteString(`<text x="` + itoa(x) + `" y="` + itoa(ty) + `" text-anchor="middle" font-size="11" fill="#e9dccf">` + esc(clip(s.Caption, 14)) + `</text>`)
		}
	}
	if n == 0 {
		b.WriteString(`<text x="210" y="80" text-anchor="middle" font-size="13" fill="#e9dccf">no members yet</text>`)
	}
	// legend
	legend := []struct {
		st    SlotState
		label string
	}{{SlotWaiting, "belum bayar"}, {SlotPaid, "sudah bayar"}, {SlotWon, "sudah dapat"}, {SlotWinner, "pemenang"}, {SlotLate, "utang"}}
	lx := 22
	for _, l := range legend {
		st := styleOf(l.st)
		b.WriteString(`<circle cx="` + itoa(lx) + `" cy="440" r="7" fill="` + st.fill + `" stroke="` + st.stroke + `" stroke-width="2"/>`)
		b.WriteString(`<text x="` + itoa(lx+12) + `" y="444" font-size="11" fill="#e9dccf">` + l.label + `</text>`)
		lx += 80
	}
	_ = w
	_ = h
	b.WriteString(`</svg>`)
	return b.String()
}

// WheelImage wraps Wheel in a markdown image with an SVG data URI, which
// gnoweb renders inline.
func WheelImage(alt string, slots []Slot, title, subtitle string) string {
	svg := Wheel(slots, title, subtitle)
	return "![" + strings.ReplaceAll(alt, "]", "") + "](data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg)) + ")"
}

func itoa(i int) string { return strconv.Itoa(i) }

func max1(n int) int {
	if n < 1 {
		return 1
	}
	return n
}

func esc(s string) string { return html.EscapeString(s) }

// clip cuts s to at most n runes, adding an ellipsis when it had to cut.
func clip(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	if n <= 1 {
		return string(r[:n])
	}
	return string(r[:n-1]) + "…"
}
