package home

import (
	"strconv"

	"gno.land/p/nym-alexiscolin000/gnoradio/svg/v0"
	"gno.land/p/nym-alexiscolin000/gnoradio/text/v0"
)

// Sober Swiss artwork, drawn on-chain as SVG and embedded by gnoweb as
// data-URI images: black and off-white, warm greys and the app's red, blue
// and yellow accents. Cards with text sit on ink so they read in light and
// dark mode alike.
// Written with a strings.Builder to keep vm/qrender gas low.

const (
	ink   = "#0d0d0d"
	paper = "#fafaf8"
	cream = "#f2efe9"
	grey  = "#c4c4c0"
	stone = "#8f8b84"
	line  = "#e3e3df"
	red   = "#e5432f"
	blue  = "#2445c9"
	amber = "#f2b51d" // the app's yellow
	dim   = "#3a3a37" // unplayed ticks on ink
	font  = "font-family:Geist,'Helvetica Neue',Helvetica,Arial,sans-serif"
)

func newCanvas(w, h int) *svg.Canvas { return svg.New(w, h, "text{"+font+"}") }

// text writes s (escaped); weight 400–800; anchor start|middle|end.
func drawText(c *svg.Canvas, x, y int, s, fill string, size, weight int, anchor, extra string) {
	c.Text(x, y, s, fill, size, ` font-weight="`+text.Itoa(weight)+`" text-anchor="`+anchor+`"`+extra)
}

// coverSVG draws one of six geometric compositions and one of three accents,
// picked from the track and its artist so neighbours differ.
func coverSVG(id, artist int, title string, size int) string {
	h := svg.FNV(strconv.Itoa(id) + "/" + strconv.Itoa(artist) + title)
	accent := [3]string{red, blue, amber}[h/6%3]
	c := newCanvas(size, size)
	s := size
	switch h % 6 {
	case 0:
		c.Rect(0, 0, s, s, s/12, ink, "")
		c.Circle(s/2, s/2, s*28/100, accent)
	case 1:
		c.Rect(0, 0, s, s, s/12, grey, "")
		c.Circle(s/5, s*9/10, s*45/100, stone)
		c.Circle(s*68/100, s*32/100, s*15/100, ink)
	case 2:
		c.Rect(0, 0, s, s, s/12, accent, "")
		c.Raw(`<path d="M0 ` + text.Itoa(s/2) + `H` + text.Itoa(s) + `V` + text.Itoa(s-s/12) + `Q` + text.Itoa(s) + ` ` + text.Itoa(s) + ` ` + text.Itoa(s-s/12) + ` ` + text.Itoa(s) +
			`H` + text.Itoa(s/12) + `Q0 ` + text.Itoa(s) + ` 0 ` + text.Itoa(s-s/12) + `Z" fill="` + cream + `"/>`)
		c.Circle(s/2, s/2, s*15/100, ink)
	case 3:
		c.Rect(0, 0, s, s, s/12, cream, "")
		c.Rect(s*14/100, s*14/100, s*44/100, s*72/100, s*22/100, stone, "")
		c.Circle(s*74/100, s*27/100, s*13/100, accent)
	case 4:
		c.Rect(0, 0, s, s, s/12, stone, "")
		c.Raw(`<path d="M` + text.Itoa(s/12) + ` 0H` + text.Itoa(s/2) + `V` + text.Itoa(s) + `H` + text.Itoa(s/12) + `Q0 ` + text.Itoa(s) + ` 0 ` + text.Itoa(s-s/12) +
			`V` + text.Itoa(s/12) + `Q0 0 ` + text.Itoa(s/12) + ` 0Z" fill="` + ink + `"/>`)
		c.Circle(s/2, s/2, s/5, cream)
	default:
		c.Rect(0, 0, s, s, s/12, ink, "")
		for i := 0; i < 21; i++ {
			th := s / 14
			if i%5 == 0 {
				th = s / 7
			}
			c.Rect(s/10+i*(s*8/10)/20, s*62/100-th, 2, th, 0, paper, "")
		}
		c.Rect(s/10+int(h%17)*(s*8/10)/20, s*36/100, 3, s*30/100, 0, accent, "")
	}
	return c.Image("cover of " + title)
}

// onAirSVG is the station banner: huge time numerals and a tick ruler with
// the red needle, as in the app, on ink so it reads in dark mode too.
func onAirSVG(station, title, artist string, offset, dur int64) string {
	const w, h = 720, 330
	c := newCanvas(w, h)
	c.Rect(0, 0, w, h, 26, ink, "")
	c.Rect(28, 26, 104, 30, 10, red, "")
	drawText(c, 80, 46, "ON AIR", "#fff", 13, 600, "middle", ` letter-spacing="1.5"`)
	c.Rect(142, 26, 18+len(station)*9, 30, 10, dim, "")
	drawText(c, 151, 46, station, paper, 13, 500, "start", "")
	if title == "" {
		drawText(c, w/2, 170, "Silence. Publish the first track.", grey, 26, 600, "middle", "")
		return c.Image("nothing on air")
	}
	t := clock(offset)
	if offset < 600 {
		t = "0" + t
	}
	lead := 0
	for lead < len(t) && (t[lead] == '0' || t[lead] == ':') {
		lead++
	}
	c.Raw(`<text x="` + text.Itoa(w/2) + `" y="150" font-size="96" font-weight="500" text-anchor="middle" letter-spacing="-4">` +
		`<tspan fill="` + dim + `">` + t[:lead] + `</tspan><tspan fill="` + paper + `">` + t[lead:] + `</tspan></text>`)
	drawText(c, w/2, 178, "of "+clock(dur)+" · synced to the last block", stone, 13, 400, "middle", "")
	frac := 0
	if dur > 0 {
		frac = int(offset * 1000 / dur)
	}
	for i := 0; i <= 80; i++ {
		th, col := 10, dim
		if i%10 == 0 {
			th = 26
		} else if i%5 == 0 {
			th = 17
		}
		if i*1000/80 <= frac {
			col = paper
		}
		c.Rect(40+i*8, 238-th, 2, th, 0, col, "")
	}
	c.Rect(40+frac*640/1000, 196, 2, 50, 0, red, "")
	// Large enough to read once the card shrinks to a phone's width.
	drawText(c, 40, 284, svg.Clip(title, 36), paper, 28, 600, "start", "")
	drawText(c, 40, 312, svg.Clip(artist, 48), grey, 18, 400, "start", "")
	return c.Image("on air: " + title)
}

// avatarSVG is a symmetric identicon in the sober palette.
func avatarSVG(seed string, size int) string {
	h := svg.FNV(seed)
	c := newCanvas(size, size)
	c.Rect(0, 0, size, size, size/2, cream, "")
	cell := size / 9
	for y := 0; y < 5; y++ {
		for x := 0; x < 3; x++ {
			h ^= uint32(y*3 + x + 1)
			h *= 16777619
			if (h>>24)%2 == 0 {
				continue
			}
			col := ink
			if (h>>20)%7 == 0 {
				col = red
			}
			c.Rect(cell*2+x*cell, cell*2+y*cell, cell, cell, 2, col, "")
			if x < 2 {
				c.Rect(cell*2+(4-x)*cell, cell*2+y*cell, cell, cell, 2, col, "")
			}
		}
	}
	return c.Image("avatar")
}

// badgeSVG is the early-listener badge.
func badgeSVG(title string, rank int) string {
	c := newCanvas(120, 120)
	c.Circle(60, 60, 58, ink)
	c.Raw(`<circle cx="60" cy="60" r="50" fill="none" stroke="` + paper + `" stroke-width="1" stroke-dasharray="3 4"/>`)
	drawText(c, 60, 50, "EARLY", grey, 11, 600, "middle", ` letter-spacing="2"`)
	drawText(c, 60, 82, "#"+text.Itoa(rank), paper, 30, 500, "middle", "")
	c.Circle(60, 100, 4, red)
	return c.Image("early listener #" + text.Itoa(rank) + " of " + title)
}

type bar struct {
	label string
	value int64
}

// barsSVG draws a horizontal bar chart.
func barsSVG(rows []bar, unit func(int64) string) string {
	h := 30 + len(rows)*40
	c := newCanvas(640, h)
	c.Rect(0, 0, 640, h, 20, ink, "")
	var max int64 = 1
	for _, r := range rows {
		if r.value > max {
			max = r.value
		}
	}
	for i, r := range rows {
		y := 20 + i*40
		w := int(r.value * 300 / max)
		if w < 4 {
			w = 4
		}
		col := paper
		if i == 0 {
			col = red
		}
		drawText(c, 20, y+20, svg.Clip(r.label, 20), paper, 14, 500, "start", "")
		c.Rect(210, y+6, w, 18, 9, col, "")
		drawText(c, 220+w, y+20, unit(r.value), grey, 13, 400, "start", "")
	}
	return c.Image("chart")
}
