// Package avatar draws Taproom's pixel gnomes as SVG: a base gnome picked from the address
// (skin, beard and cap colour) and up to four equipped items layered on top. Any realm can import
// it to show the same gnome a player wears in Taproom.
//
//	svg := avatar.Render(addr, [4]int{107, 201, 0, 403}) // hat, outfit, held item, companion
//	img := "![gnome](" + avatar.DataURI(addr, equipped) + ")" // for Render() markdown
//
// Item IDs are slotBase + n with slotBase 100 hat, 200 outfit, 300 held, 400 companion and
// n = 1..12; 0 means nothing in that slot. Unknown IDs, and IDs in the wrong slot, are ignored.
// The art lives in layers.gno, generated from the web app's layer SVGs.
package avatar

import (
	"encoding/base64"
	"strconv"
	"strings"
)

// alphabet decodes the 4-character runs in layers.gno: x, y, length - 1, colour index.
const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"

// Combo picks one of 8 base gnomes from the address, the same way the web app does:
// h = 7; h = h*31 + byte for each character (uint32); combo = h % 8.
func Combo(addr address) int {
	s := addr.String()
	h := uint32(7)
	for i := 0; i < len(s); i++ {
		h = h*31 + uint32(s[i])
	}
	return int(h % 8)
}

// ValidItem reports whether id is one of the 48 catalogue items.
func ValidItem(id int) bool {
	_, ok := items[id]
	return ok
}

// Render returns a 96 x 96 px SVG (48 x 48 pixel grid) of addr's gnome wearing the equipped items
// (hat, outfit, held, companion). Layers back to front: companion, body, outfit, head, hat or cap, held.
func Render(addr address, equipped [4]int) string {
	c := Combo(addr)
	item := func(slot int) ([2]string, bool) {
		id := equipped[slot]
		it, ok := items[id]
		return it, ok && id/100 == slot+1
	}
	var sb strings.Builder
	sb.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="96" height="96" shape-rendering="crispEdges">`)
	if it, ok := item(3); ok {
		sb.WriteString(layerSVG(it[0], it[1]))
	}
	sb.WriteString(layerSVG(bodyPal[c], bodyRuns))
	if it, ok := item(1); ok {
		sb.WriteString(layerSVG(it[0], it[1]))
	}
	sb.WriteString(layerSVG(headPal[c], headRuns))
	if it, ok := item(0); ok {
		sb.WriteString(layerSVG(it[0], it[1]))
	} else {
		sb.WriteString(layerSVG(capPal[c], capRuns))
	}
	if it, ok := item(2); ok {
		sb.WriteString(layerSVG(it[0], it[1]))
	}
	sb.WriteString("</svg>")
	return sb.String()
}

// DataURI returns Render's SVG as a base64 data URI, for an <img> or a markdown image.
func DataURI(addr address, equipped [4]int) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(Render(addr, equipped)))
}

// num holds "0".."64" so drawing a run needs no number formatting.
var num [65]string

func init() {
	for i := range num {
		num[i] = strconv.Itoa(i)
	}
}

// dec decodes one character of the run alphabet.
func dec(b byte) int {
	switch {
	case b == '-':
		return 62
	case b == '_':
		return 63
	case b <= '9':
		return int(b - '0')
	case b <= 'Z':
		return int(b-'A') + 10
	}
	return int(b-'a') + 36
}

// layerSVG draws one layer as a <g> with one path per colour. Each run is a 1 px stroke along the
// middle of its pixel row (M x y.5 h w), which covers exactly the run's pixels with crisp edges.
func layerSVG(palette, runs string) string {
	n := len(palette) / 6
	paths := make([]strings.Builder, n)
	for i := 0; i+3 < len(runs); i += 4 {
		p := &paths[dec(runs[i+3])]
		p.WriteString("M")
		p.WriteString(num[dec(runs[i])])
		p.WriteString(" ")
		p.WriteString(num[dec(runs[i+1])])
		p.WriteString(".5h")
		p.WriteString(num[dec(runs[i+2])+1])
	}
	var sb strings.Builder
	sb.WriteString("<g>")
	for i := 0; i < n; i++ {
		if paths[i].Len() == 0 {
			continue
		}
		sb.WriteString(`<path stroke="#`)
		sb.WriteString(palette[i*6 : i*6+6])
		sb.WriteString(`" d="`)
		sb.WriteString(paths[i].String())
		sb.WriteString(`"/>`)
	}
	sb.WriteString("</g>")
	return sb.String()
}
