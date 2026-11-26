package ring

import (
	"encoding/base64"
	"math"
	"strconv"
	"strings"
)

// GraphHop describes one swap in a ring for SVG rendering.
// All strings are untrusted display labels; GraphSVG strips invisible/control
// runes, truncates overly long labels, and XML-escapes every byte.
type GraphHop struct {
	From string // display label for the giving owner (e.g. "@alice" or "g1ab…wxyz")
	Give string // display label for what moves (e.g. "500 OBOL" or "Relic #2")
	Want string // for bridged hops: what the next owner wants (e.g. "≥ 50 DRACHMA")
	Note string // optional line under Give, e.g. the realm the asset lives in
	// WantNote, for bridged hops, is the same for the wanted token; it is
	// drawn on a line of its own after Note.
	WantNote string
	OfferID  uint64 // offer id, shown inside full-size nodes when non-zero
	Bridged  bool   // true when swapped through GnoSwap
}

// GraphSize selects between a full-size ring diagram (ring page) and a compact
// thumbnail (home page cards).
type GraphSize uint8

const (
	GraphFull  GraphSize = 0
	GraphThumb GraphSize = 1
)

// Precomputed (cos, sin) unit-circle coordinates starting at -pi/2 (top),
// moving clockwise for rings of 3 to 6 nodes. Avoids trig calls in GnoVM.
var ringUnitCoords = [7][][2]float64{
	3: {
		{0.0, -1.0},
		{0.866025, 0.5},
		{-0.866025, 0.5},
	},
	4: {
		{0.0, -1.0},
		{1.0, 0.0},
		{0.0, 1.0},
		{-1.0, 0.0},
	},
	5: {
		{0.0, -1.0},
		{0.951057, -0.309017},
		{0.587785, 0.809017},
		{-0.587785, 0.809017},
		{-0.951057, -0.309017},
	},
	6: {
		{0.0, -1.0},
		{0.866025, -0.5},
		{0.866025, 0.5},
		{0.0, 1.0},
		{-0.866025, 0.5},
		{-0.866025, -0.5},
	},
}

// GraphSVG returns a self-contained SVG document illustrating a closed ring of
// MinLegs to MaxLegs swaps. It returns "" when len(hops) is out of range.
//
// The diagram draws on its own warm-neutral framed surface so text and arrows
// keep crisp contrast on both light and dark host pages, even when a host
// toggles themes via CSS classes that an <img> SVG cannot read.
func GraphSVG(hops []GraphHop, size GraphSize) string {
	n := len(hops)
	if n < MinLegs || n > MaxLegs {
		return ""
	}
	if n == 2 {
		return renderTwoRingSVG(hops, size)
	}
	return renderPolygonRingSVG(hops, size)
}

// GraphDataURI encodes GraphSVG as a base64 data URI suitable for Markdown
// image syntax `![alt](data:image/svg+xml;base64,...)`. Returns "" if
// len(hops) is out of range.
func GraphDataURI(hops []GraphHop, size GraphSize) string {
	doc := GraphSVG(hops, size)
	if doc == "" {
		return ""
	}
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(doc))
}

type point struct{ x, y float64 }

func renderTwoRingSVG(hops []GraphHop, size GraphSize) string {
	thumb := size == GraphThumb
	w, h := 640, 260
	nodeW, nodeH := 156.0, 48.0
	cx, cy := 320.0, 130.0
	leftX, rightX := 112.0, 528.0
	topCtrlY, botCtrlY := 24.0, 236.0
	topLblY, botLblY := 56.0, 204.0
	nodeFont, subFont, lblFont, centerFont := 13, 11, 12, 12
	maxOwner, maxAsset := 16, 28
	if thumb {
		w, h = 420, 178
		nodeW, nodeH = 120.0, 34.0
		cx, cy = 210.0, 89.0
		leftX, rightX = 76.0, 344.0
		topCtrlY, botCtrlY = 14.0, 164.0
		topLblY, botLblY = 35.0, 143.0
		nodeFont, subFont, lblFont, centerFont = 12, 10, 11, 11
		maxOwner, maxAsset = 13, 20
	}

	var sb strings.Builder
	writeSVGHeader(&sb, w, h, hasBridged(hops))

	sb.WriteString(`<ellipse cx="`)
	sb.WriteString(px(cx))
	sb.WriteString(`" cy="`)
	sb.WriteString(px(cy))
	sb.WriteString(`" rx="`)
	sb.WriteString(px((rightX-leftX)/2 - nodeW*0.35))
	sb.WriteString(`" ry="`)
	sb.WriteString(px((botLblY - topLblY) * 0.32))
	sb.WriteString(`" fill="none" stroke="#e4ddd2" stroke-dasharray="3,4"/>`)

	writeCenterSummary(&sb, cx, cy, hops, centerFont, thumb)

	padX := nodeW * 0.30
	padY := nodeH*0.5 + 5.0
	drawCurvedArrow(&sb, point{leftX + padX, cy - padY}, point{cx, topCtrlY}, point{rightX - padX, cy - padY}, hops[0].Bridged)
	drawCurvedArrow(&sb, point{rightX - padX, cy + padY}, point{cx, botCtrlY}, point{leftX + padX, cy + padY}, hops[1].Bridged)

	drawHopLabel(&sb, cx, topLblY, hops[0], lblFont, maxAsset, thumb, float64(w), float64(h))
	drawHopLabel(&sb, cx, botLblY, hops[1], lblFont, maxAsset, thumb, float64(w), float64(h))

	drawNode(&sb, leftX, cy, nodeW, nodeH, hops[0], nodeFont, subFont, maxOwner, thumb)
	drawNode(&sb, rightX, cy, nodeW, nodeH, hops[1], nodeFont, subFont, maxOwner, thumb)

	sb.WriteString(`</svg>`)
	return sb.String()
}

func renderPolygonRingSVG(hops []GraphHop, size GraphSize) string {
	n := len(hops)
	thumb := size == GraphThumb

	w, h := 680, 440
	cx, cy := 340.0, 220.0
	nodeW, nodeH := 142.0, 46.0
	rx, ry := 190.0, 134.0
	bow := 26.0
	lblPush := 13.0
	nodeFont, subFont, lblFont, centerFont := 13, 11, 11, 12
	maxOwner, maxAsset := 15, 24

	switch n {
	case 3:
		rx, ry, bow = 195.0, 132.0, 30.0
	case 4:
		rx, ry, bow = 205.0, 136.0, 24.0
	case 5:
		nodeW = 132.0
		rx, ry, bow = 212.0, 144.0, 22.0
		maxOwner, maxAsset = 13, 20
	case 6:
		nodeW = 128.0
		rx, ry, bow = 220.0, 148.0, 20.0
		maxOwner, maxAsset = 12, 18
	}

	if thumb {
		w, h = 420, 276
		cx, cy = 210.0, 138.0
		nodeW, nodeH = 104.0, 30.0
		rx, ry, bow = 122.0, 82.0, 18.0
		lblPush = 9.0
		nodeFont, subFont, lblFont, centerFont = 11, 9, 10, 10
		maxOwner, maxAsset = 11, 15
		if n >= 5 {
			nodeW = 94.0
			rx, ry, bow = 132.0, 88.0, 14.0
			maxOwner, maxAsset = 9, 12
		}
	}

	coords := ringUnitCoords[n]
	pos := make([]point, n)
	for i := 0; i < n; i++ {
		pos[i] = point{
			x: cx + rx*coords[i][0],
			y: cy + ry*coords[i][1],
		}
	}

	var sb strings.Builder
	writeSVGHeader(&sb, w, h, hasBridged(hops))

	sb.WriteString(`<ellipse cx="`)
	sb.WriteString(px(cx))
	sb.WriteString(`" cy="`)
	sb.WriteString(px(cy))
	sb.WriteString(`" rx="`)
	sb.WriteString(px(rx))
	sb.WriteString(`" ry="`)
	sb.WriteString(px(ry))
	sb.WriteString(`" fill="none" stroke="#e4ddd2" stroke-dasharray="3,4"/>`)

	writeCenterSummary(&sb, cx, cy, hops, centerFont, thumb)

	labelPts := make([]point, n)
	hw, hh := nodeW/2, nodeH/2
	padStart := 4.0
	padEnd := 9.0

	for i := 0; i < n; i++ {
		j := (i + 1) % n
		p0, p1 := pos[i], pos[j]
		mx, my := (p0.x+p1.x)/2, (p0.y+p1.y)/2

		nx, ny := mx-cx, my-cy
		nlen := math.Sqrt(nx*nx + ny*ny)
		if nlen < 1e-6 {
			nx, ny = 0, -1
		} else {
			nx, ny = nx/nlen, ny/nlen
		}

		ctrl := point{mx + nx*bow, my + ny*bow}
		start := exitPill(p0, ctrl, hw+padStart, hh+padStart)
		end := exitPill(p1, ctrl, hw+padEnd, hh+padEnd)
		drawCurvedArrow(&sb, start, ctrl, end, hops[i].Bridged)

		bx := 0.25*start.x + 0.5*ctrl.x + 0.25*end.x
		by := 0.25*start.y + 0.5*ctrl.y + 0.25*end.y
		labelPts[i] = point{bx + nx*lblPush, by + ny*lblPush}
	}

	for i := 0; i < n; i++ {
		drawNode(&sb, pos[i].x, pos[i].y, nodeW, nodeH, hops[i], nodeFont, subFont, maxOwner, thumb)
	}
	for i := 0; i < n; i++ {
		drawHopLabel(&sb, labelPts[i].x, labelPts[i].y, hops[i], lblFont, maxAsset, thumb, float64(w), float64(h))
	}

	sb.WriteString(`</svg>`)
	return sb.String()
}

func exitPill(center, target point, hw, hh float64) point {
	dx, dy := target.x-center.x, target.y-center.y
	d := math.Sqrt(dx*dx + dy*dy)
	if d < 1e-6 {
		return center
	}
	ux, uy := dx/d, dy/d
	tx := 1e9
	if ux < -1e-6 {
		tx = hw / -ux
	} else if ux > 1e-6 {
		tx = hw / ux
	}
	ty := 1e9
	if uy < -1e-6 {
		ty = hh / -uy
	} else if uy > 1e-6 {
		ty = hh / uy
	}
	t := tx
	if ty < t {
		t = ty
	}
	return point{center.x + ux*t, center.y + uy*t}
}

func writeSVGHeader(sb *strings.Builder, w, h int, withBridge bool) {
	ws, hs := strconv.Itoa(w), strconv.Itoa(h)
	sb.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="`)
	sb.WriteString(ws)
	sb.WriteString(`" height="`)
	sb.WriteString(hs)
	sb.WriteString(`" viewBox="0 0 `)
	sb.WriteString(ws)
	sb.WriteByte(' ')
	sb.WriteString(hs)
	sb.WriteString(`" role="img" aria-label="Kylix trade ring"><style>text{font-family:system-ui,-apple-system,sans-serif;text-anchor:middle}</style><defs>`)
	sb.WriteString(`<marker id="ah-direct" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse"><path d="M1,1.5 L9,5 L1,8.5 z" fill="#146c67"/></marker>`)
	if withBridge {
		sb.WriteString(`<marker id="ah-bridge" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse"><path d="M1,1.5 L9,5 L1,8.5 z" fill="#c85619"/></marker>`)
	}
	sb.WriteString(`</defs><rect x="1" y="1" width="`)
	sb.WriteString(strconv.Itoa(w - 2))
	sb.WriteString(`" height="`)
	sb.WriteString(strconv.Itoa(h - 2))
	sb.WriteString(`" rx="14" fill="#faf8f4" stroke="#d8d1c5" stroke-width="1.5"/>`)
}

func drawCurvedArrow(sb *strings.Builder, start, ctrl, end point, bridged bool) {
	sb.WriteString(`<path d="M`)
	sb.WriteString(px(start.x))
	sb.WriteByte(',')
	sb.WriteString(px(start.y))
	sb.WriteString(` Q`)
	sb.WriteString(px(ctrl.x))
	sb.WriteByte(',')
	sb.WriteString(px(ctrl.y))
	sb.WriteByte(' ')
	sb.WriteString(px(end.x))
	sb.WriteByte(',')
	sb.WriteString(px(end.y))
	if bridged {
		sb.WriteString(`" fill="none" stroke="#c85619" stroke-width="2.5" stroke-linecap="round" stroke-dasharray="6,4" marker-end="url(#ah-bridge)"/>`)
		return
	}
	sb.WriteString(`" fill="none" stroke="#146c67" stroke-width="2.2" stroke-linecap="round" marker-end="url(#ah-direct)"/>`)
}

func drawNode(sb *strings.Builder, x, y, w, h float64, hop GraphHop, fontSize, subFont, maxOwner int, thumb bool) {
	owner := clipLabel(cleanSVGText(hop.From), maxOwner)
	if owner == "" {
		owner = "owner"
	}
	sb.WriteString(`<rect x="`)
	sb.WriteString(px(x - w/2))
	sb.WriteString(`" y="`)
	sb.WriteString(px(y - h/2))
	sb.WriteString(`" width="`)
	sb.WriteString(px(w))
	sb.WriteString(`" height="`)
	sb.WriteString(px(h))
	sb.WriteString(`" rx="`)
	sb.WriteString(px(h / 2))
	sb.WriteString(`" fill="#fff" stroke="#2c3e50" stroke-width="1.6"/>`)

	if thumb || hop.OfferID == 0 {
		sb.WriteString(`<text x="`)
		sb.WriteString(px(x))
		sb.WriteString(`" y="`)
		sb.WriteString(px(y + float64(fontSize)*0.35))
		sb.WriteString(`" font-size="`)
		sb.WriteString(strconv.Itoa(fontSize))
		sb.WriteString(`" font-weight="600" fill="#16202a">`)
		writeEscapedXML(sb, owner)
		sb.WriteString(`</text>`)
		return
	}
	sb.WriteString(`<text x="`)
	sb.WriteString(px(x))
	sb.WriteString(`" y="`)
	sb.WriteString(px(y - 3))
	sb.WriteString(`" font-size="`)
	sb.WriteString(strconv.Itoa(fontSize))
	sb.WriteString(`" font-weight="600" fill="#16202a">`)
	writeEscapedXML(sb, owner)
	sb.WriteString(`</text><text x="`)
	sb.WriteString(px(x))
	sb.WriteString(`" y="`)
	sb.WriteString(px(y + 13))
	sb.WriteString(`" font-size="`)
	sb.WriteString(strconv.Itoa(subFont))
	sb.WriteString(`" fill="#5b6774">offer #`)
	sb.WriteString(strconv.FormatUint(hop.OfferID, 10))
	sb.WriteString(`</text>`)
}

func drawHopLabel(sb *strings.Builder, x, y float64, hop GraphHop, fontSize, maxChars int, thumb bool, canvasW, canvasH float64) {
	give := clipLabel(cleanSVGText(hop.Give), maxChars)
	if give == "" {
		give = "asset"
	}

	if hop.Bridged {
		line1 := "via GnoSwap"
		line2 := give
		if !thumb && hop.Want != "" {
			line2 = clipLabel(cleanSVGText(hop.Give)+" → "+cleanSVGText(hop.Want), maxChars+8)
		}
		charW := float64(fontSize) * 0.60
		maxLen := runeCount(line1)
		if l2 := runeCount(line2); l2 > maxLen {
			maxLen = l2
		}
		pillW := float64(maxLen)*charW + 18
		if pillW < 84 {
			pillW = 84
		}
		pillH := float64(fontSize)*2.5 + 10
		note := clipLabel(cleanSVGText(hop.Note), maxNoteRunes)
		wantNote := clipLabel(cleanSVGText(hop.WantNote), maxNoteRunes)
		if wantNote != "" {
			wantNote = "→ " + wantNote
		}
		for _, n := range []string{note, wantNote} {
			if n == "" {
				continue
			}
			if w := float64(runeCount(n))*charW*0.85 + 18; w > pillW {
				pillW = w
			}
			pillH += float64(fontSize)
		}
		cx, cy := clampBox(x, y, pillW, pillH, canvasW, canvasH)
		ty := cy // text block centre: note lines shift the first two up
		if note != "" {
			ty -= float64(fontSize) / 2
		}
		if wantNote != "" {
			ty -= float64(fontSize) / 2
		}

		sb.WriteString(`<rect x="`)
		sb.WriteString(px(cx - pillW/2))
		sb.WriteString(`" y="`)
		sb.WriteString(px(cy - pillH/2))
		sb.WriteString(`" width="`)
		sb.WriteString(px(pillW))
		sb.WriteString(`" height="`)
		sb.WriteString(px(pillH))
		sb.WriteString(`" rx="8" fill="#fff5ed" stroke="#df8a57" stroke-width="1.4"/><text x="`)
		sb.WriteString(px(cx))
		sb.WriteString(`" y="`)
		sb.WriteString(px(ty - float64(fontSize)*0.25))
		sb.WriteString(`" font-size="`)
		sb.WriteString(strconv.Itoa(fontSize - 1))
		sb.WriteString(`" font-weight="700" fill="#b4460b">`)
		sb.WriteString(line1)
		sb.WriteString(`</text><text x="`)
		sb.WriteString(px(cx))
		sb.WriteString(`" y="`)
		sb.WriteString(px(ty + float64(fontSize)*0.95))
		sb.WriteString(`" font-size="`)
		sb.WriteString(strconv.Itoa(fontSize))
		sb.WriteString(`" font-weight="500" fill="#6b2a08">`)
		writeEscapedXML(sb, line2)
		sb.WriteString(`</text>`)
		ny := ty + float64(fontSize)*2.05
		if note != "" {
			writeNoteLine(sb, cx, ny, fontSize, note)
			ny += float64(fontSize)
		}
		if wantNote != "" {
			writeNoteLine(sb, cx, ny, fontSize, wantNote)
		}
		return
	}

	charW := float64(fontSize) * 0.60
	pillW := float64(runeCount(give))*charW + 16
	if pillW < 56 {
		pillW = 56
	}
	pillH := float64(fontSize) + 12
	note := clipLabel(cleanSVGText(hop.Note), maxNoteRunes)
	if note != "" {
		if w := float64(runeCount(note))*charW*0.85 + 16; w > pillW {
			pillW = w
		}
		pillH += float64(fontSize)
	}
	cx, cy := clampBox(x, y, pillW, pillH, canvasW, canvasH)
	textY := cy + float64(fontSize)*0.35
	if note != "" {
		textY = cy - float64(fontSize)*0.15
	}

	sb.WriteString(`<rect x="`)
	sb.WriteString(px(cx - pillW/2))
	sb.WriteString(`" y="`)
	sb.WriteString(px(cy - pillH/2))
	sb.WriteString(`" width="`)
	sb.WriteString(px(pillW))
	sb.WriteString(`" height="`)
	sb.WriteString(px(pillH))
	sb.WriteString(`" rx="7" fill="#fff" stroke="#b5d6d3" stroke-width="1.2"/><text x="`)
	sb.WriteString(px(cx))
	sb.WriteString(`" y="`)
	sb.WriteString(px(textY))
	sb.WriteString(`" font-size="`)
	sb.WriteString(strconv.Itoa(fontSize))
	sb.WriteString(`" font-weight="500" fill="#104946">`)
	writeEscapedXML(sb, give)
	sb.WriteString(`</text>`)
	if note != "" {
		writeNoteLine(sb, cx, textY+float64(fontSize)*1.05, fontSize, note)
	}
}

// maxNoteRunes bounds a note line. Notes are realm hints, which the caller
// keeps short without cutting the namespace; they are not clipped to the
// asset label's width, because a clipped namespace could be ambiguous.
const maxNoteRunes = 80

// writeNoteLine draws a hop's note (already cleaned and clipped) in a
// smaller, muted font.
func writeNoteLine(sb *strings.Builder, x, y float64, fontSize int, note string) {
	sb.WriteString(`<text x="`)
	sb.WriteString(px(x))
	sb.WriteString(`" y="`)
	sb.WriteString(px(y))
	sb.WriteString(`" font-size="`)
	sb.WriteString(strconv.Itoa(fontSize - 2))
	sb.WriteString(`" fill="#5b6774">`)
	writeEscapedXML(sb, note)
	sb.WriteString(`</text>`)
}

func writeCenterSummary(sb *strings.Builder, cx, cy float64, hops []GraphHop, fontSize int, thumb bool) {
	nStr := strconv.Itoa(len(hops)) + " swaps"
	if hasBridged(hops) && !thumb {
		sb.WriteString(`<text x="`)
		sb.WriteString(px(cx))
		sb.WriteString(`" y="`)
		sb.WriteString(px(cy - 4))
		sb.WriteString(`" font-size="`)
		sb.WriteString(strconv.Itoa(fontSize))
		sb.WriteString(`" font-weight="600" fill="#5e6873">`)
		sb.WriteString(nStr)
		sb.WriteString(`</text><text x="`)
		sb.WriteString(px(cx))
		sb.WriteString(`" y="`)
		sb.WriteString(px(cy + 12))
		sb.WriteString(`" font-size="`)
		sb.WriteString(strconv.Itoa(fontSize - 1))
		sb.WriteString(`" fill="#b4460b">1 via GnoSwap</text>`)
		return
	}
	sb.WriteString(`<text x="`)
	sb.WriteString(px(cx))
	sb.WriteString(`" y="`)
	sb.WriteString(px(cy + float64(fontSize)*0.35))
	sb.WriteString(`" font-size="`)
	sb.WriteString(strconv.Itoa(fontSize))
	sb.WriteString(`" font-weight="600" fill="#6b747e">`)
	sb.WriteString(nStr)
	sb.WriteString(`</text>`)
}

func clampBox(x, y, w, h, canvasW, canvasH float64) (float64, float64) {
	const margin = 10.0
	minX := margin + w/2
	maxX := canvasW - margin - w/2
	minY := margin + h/2
	maxY := canvasH - margin - h/2
	if minX <= maxX {
		if x < minX {
			x = minX
		} else if x > maxX {
			x = maxX
		}
	}
	if minY <= maxY {
		if y < minY {
			y = minY
		} else if y > maxY {
			y = maxY
		}
	}
	return x, y
}

func hasBridged(hops []GraphHop) bool {
	for _, h := range hops {
		if h.Bridged {
			return true
		}
	}
	return false
}

// cleanSVGText strips control, zero-width, line-separator, and bidi override
// runes and folds whitespace to single spaces.
func cleanSVGText(s string) string {
	// Fast path for clean printable ASCII without repeated/leading/trailing spaces.
	clean := true
	prevSpace := true
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == ' ' {
			if prevSpace {
				clean = false
				break
			}
			prevSpace = true
		} else if c < 0x20 || c >= 0x7f {
			clean = false
			break
		} else {
			prevSpace = false
		}
	}
	if clean && !prevSpace {
		return s
	}

	var sb strings.Builder
	prevSpace = false
	for _, r := range s {
		switch {
		case r == '\n' || r == '\r' || r == '\t' || r == ' ':
			if !prevSpace && sb.Len() > 0 {
				sb.WriteByte(' ')
				prevSpace = true
			}
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0):
			// drop control characters
		case (r >= 0x200b && r <= 0x200f) || (r >= 0x2028 && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) || r == 0xfeff:
			// drop zero-width, line separators, bidi overrides
		default:
			sb.WriteRune(r)
			prevSpace = false
		}
	}
	return strings.TrimRight(sb.String(), " ")
}

func clipLabel(s string, maxRunes int) string {
	if maxRunes <= 1 || len(s) <= maxRunes {
		return s
	}
	count := 0
	for i := range s {
		if count == maxRunes-1 {
			if runeCount(s[i:]) > 1 {
				return s[:i] + "…"
			}
			return s
		}
		count++
	}
	return s
}

func runeCount(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
}

func writeEscapedXML(sb *strings.Builder, s string) {
	if !strings.ContainsAny(s, "&<>\"'") {
		sb.WriteString(s)
		return
	}
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '&':
			sb.WriteString("&amp;")
		case '<':
			sb.WriteString("&lt;")
		case '>':
			sb.WriteString("&gt;")
		case '"':
			sb.WriteString("&quot;")
		case '\'':
			sb.WriteString("&#39;")
		default:
			sb.WriteByte(s[i])
		}
	}
}

// px rounds v to the nearest integer pixel string.
func px(v float64) string {
	if v < 0 {
		return strconv.Itoa(int(v - 0.5))
	}
	return strconv.Itoa(int(v + 0.5))
}
