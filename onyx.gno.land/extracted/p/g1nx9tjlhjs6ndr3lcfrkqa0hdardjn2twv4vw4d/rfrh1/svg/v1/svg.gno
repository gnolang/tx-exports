// Package svg draws Ribbonfight boards and replays as SVG images.
//
// gnoweb strips raw <svg> from Markdown, so every picture is returned as a
// data URI that Markdown can embed with ![alt](uri). Replays animate with
// SMIL inside the image (no script), which gnoweb's CSP allows.
//
// Coordinates use one unit per cell; trails are single paths through cell
// centres, so an image stays small even for long games.
package svg

import (
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/rfrh1/rules/v1"
)

// Colours.
const (
	bg     = "#14141c"
	grid   = "#1f1f2b"
	wall   = "#4a4a5e"
	colA   = "#ff3df0"
	colB   = "#2de2ff"
	dead   = "#ff4040"
	cellPx = 16
)

// Track is the list of cells a ribbon occupied, in order, plus how it died.
type Track struct {
	Cells []rules.Point
	Death int
}

// Tracks replays a match string up to turn t (t < 0 for the whole game) and
// returns the board map, both tracks and the game.
func Tracks(match string, t int) (rules.Map, [2]Track, *rules.Game, error) {
	var tr [2]Track
	m, mv, err := rules.Decode(match)
	if err != nil {
		return m, tr, nil, err
	}
	g := rules.NewGame(m)
	for s := 0; s < 2; s++ {
		tr[s].Cells = append(tr[s].Cells, g.Head(s))
	}
	for i, c := range mv {
		if t >= 0 && i >= t {
			break
		}
		if g.Over() {
			return m, tr, nil, rules.ErrBadMatch
		}
		v := int(c - 'a')
		g.Apply(v/5, v%5)
		if !g.Over() {
			for s := 0; s < 2; s++ {
				tr[s].Cells = append(tr[s].Cells, g.Head(s))
			}
		}
	}
	r := g.Result()
	tr[0].Death, tr[1].Death = r.DeathA, r.DeathB
	return m, tr, g, nil
}

// Frame returns an SVG of the board after turn t (t < 0 for the end).
func Frame(match string, t int) (string, error) {
	m, tr, _, err := Tracks(match, t)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	open(&b, m)
	for s := 0; s < 2; s++ {
		b.WriteString(`<path d="` + pathD(tr[s].Cells) + `" stroke="` + color(s) + `" stroke-width="0.62" fill="none" stroke-linecap="round" stroke-linejoin="round"/>`)
	}
	for s := 0; s < 2; s++ {
		head(&b, tr[s], s, "")
	}
	b.WriteString("</svg>")
	return b.String(), nil
}

// Animated returns an SVG that replays the whole match and loops, holding the
// final position for a moment. stepMs is the time per turn.
func Animated(match string, stepMs int) (string, error) {
	m, tr, _, err := Tracks(match, -1)
	if err != nil {
		return "", err
	}
	if stepMs < 20 {
		stepMs = 20
	}
	segs := len(tr[0].Cells) - 1
	playMs := segs * stepMs
	if playMs < 400 {
		playMs = 400
	}
	holdMs := 1800
	total := playMs + holdMs
	split := ratio(playMs, total)
	dur := strconv.Itoa(total) + "ms"
	var b strings.Builder
	open(&b, m)
	L := strconv.Itoa(segs + 1)
	for s := 0; s < 2; s++ {
		b.WriteString(`<path d="` + pathD(tr[s].Cells) + `" stroke="` + color(s) + `" stroke-width="0.62" fill="none" stroke-linecap="round" stroke-linejoin="round" stroke-dasharray="` + L + ` ` + L + `" stroke-dashoffset="` + L + `">`)
		b.WriteString(`<animate attributeName="stroke-dashoffset" values="` + L + `;0;0" keyTimes="0;` + split + `;1" dur="` + dur + `" repeatCount="indefinite"/></path>`)
	}
	// Death markers fade in when the replay reaches the end.
	anim := `<animate attributeName="opacity" values="0;0;1;1" keyTimes="0;` + split + `;` + split + `;1" dur="` + dur + `" repeatCount="indefinite"/>`
	for s := 0; s < 2; s++ {
		head(&b, tr[s], s, anim)
	}
	b.WriteString("</svg>")
	return b.String(), nil
}

// DataURI wraps an SVG document for Markdown image embedding.
func DataURI(svg string) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
}

// Image returns a Markdown image of an SVG document. alt is escaped.
func Image(alt, svg string) string {
	return "![" + escapeAlt(alt) + "](" + DataURI(svg) + ")"
}

func open(b *strings.Builder, m rules.Map) {
	w, h := strconv.Itoa(m.W()), strconv.Itoa(m.H())
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="` + strconv.Itoa(m.W()*cellPx) + `" height="` + strconv.Itoa(m.H()*cellPx) + `" viewBox="0 0 ` + w + ` ` + h + `">`)
	b.WriteString(`<defs><pattern id="g" width="1" height="1" patternUnits="userSpaceOnUse"><path d="M1 0H0V1" fill="none" stroke="` + grid + `" stroke-width="0.06"/></pattern></defs>`)
	b.WriteString(`<rect width="` + w + `" height="` + h + `" fill="` + bg + `"/><rect width="` + w + `" height="` + h + `" fill="url(#g)"/>`)
	// Walls as one path of unit squares.
	var wp strings.Builder
	for y := 0; y < m.H(); y++ {
		for x := 0; x < m.W(); x++ {
			if m.Wall(x, y) {
				wp.WriteString("M" + strconv.Itoa(x) + " " + strconv.Itoa(y) + "h1v1h-1z")
			}
		}
	}
	if wp.Len() > 0 {
		b.WriteString(`<path d="` + wp.String() + `" fill="` + wall + `"/>`)
	}
}

func head(b *strings.Builder, t Track, side int, anim string) {
	p := t.Cells[len(t.Cells)-1]
	cx, cy := half(p.X), half(p.Y)
	b.WriteString(`<circle cx="` + cx + `" cy="` + cy + `" r="0.42" fill="` + color(side) + `"`)
	if anim != "" {
		// The head rides along with the trail only at the end; keep it simple.
		b.WriteString(` opacity="0">` + anim + `</circle>`)
	} else {
		b.WriteString(`/>`)
	}
	if t.Death == rules.Alive {
		return
	}
	x0, y0 := strconv.Itoa(p.X), strconv.Itoa(p.Y)
	b.WriteString(`<path d="M` + x0 + ` ` + y0 + `l1 1M` + strconv.Itoa(p.X+1) + ` ` + y0 + `l-1 1" stroke="` + dead + `" stroke-width="0.22"`)
	if anim != "" {
		b.WriteString(` opacity="0">` + anim + `</path>`)
	} else {
		b.WriteString(`/>`)
	}
}

func pathD(cells []rules.Point) string {
	var b strings.Builder
	for i, p := range cells {
		if i == 0 {
			b.WriteString("M")
		} else {
			b.WriteString("L")
		}
		b.WriteString(half(p.X) + " " + half(p.Y))
	}
	if len(cells) == 1 {
		b.WriteString("h0.01")
	}
	return b.String()
}

func half(n int) string { return strconv.Itoa(n) + ".5" }

func color(side int) string {
	if side == rules.SideA {
		return colA
	}
	return colB
}

// ratio formats a/b with 3 decimals, for keyTimes.
func ratio(a, b int) string {
	v := a * 1000 / b
	s := strconv.Itoa(v)
	for len(s) < 3 {
		s = "0" + s
	}
	return "0." + s
}

func escapeAlt(s string) string {
	r := strings.NewReplacer("[", "", "]", "", "(", "", ")", "", "<", "", ">", "", "\n", " ")
	return r.Replace(s)
}
