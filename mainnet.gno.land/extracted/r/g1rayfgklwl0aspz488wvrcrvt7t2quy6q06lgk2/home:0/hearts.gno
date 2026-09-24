package home

import (
	"encoding/base64"
	"strconv"
	"strings"
)

// The hearts wall draws one red heart per address that sent one, row by row,
// with the slots still free in the last row left as outlines. Past
// wallCols*wallMaxRows hearts the wall stays full and a line under it counts
// the rest, so the image never grows past ten rows.

const (
	wallCols    = 24
	wallMaxRows = 10
	wallCell    = 28
	heartRed    = "#e63946"
	heartPath   = "M12 21C12 21 3 15.5 3 9.5 3 6.5 5.4 4 8.3 4 10 4 11.2 5 12 6.2 12.8 5 14 4 15.7 4 18.6 4 21 6.5 21 9.5 21 15.5 12 21 12 21Z"
)

// renderHeartsWall returns the wall as a markdown image; with no heart yet it
// is one row of empty slots.
func renderHeartsWall() string {
	n := Hearts()
	shown := n
	if limit := wallCols * wallMaxRows; shown > limit {
		shown = limit
	}
	rows := shown/wallCols + 1
	if rows > wallMaxRows {
		rows = wallMaxRows
	}
	w := 24 + wallCols*wallCell
	h := 24 + rows*wallCell
	more := n - shown
	if more > 0 {
		h += 26
	}
	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="` + strconv.Itoa(w) + `" height="` + strconv.Itoa(h) +
		`" viewBox="0 0 ` + strconv.Itoa(w) + ` ` + strconv.Itoa(h) + `"><defs><path id="h" d="` + heartPath + `"/></defs>`)
	b.WriteString(`<rect width="` + strconv.Itoa(w) + `" height="` + strconv.Itoa(h) + `" rx="12" fill="#10231c"/>`)
	for i := 0; i < rows*wallCols; i++ {
		x := 14 + (i%wallCols)*wallCell
		y := 14 + (i/wallCols)*wallCell
		style := `fill="` + heartRed + `"`
		if i >= shown {
			style = `fill="none" stroke="#6b8f7f" stroke-width="1.5"`
		}
		b.WriteString(`<use href="#h" x="` + strconv.Itoa(x) + `" y="` + strconv.Itoa(y) + `" ` + style + `/>`)
	}
	if more > 0 {
		b.WriteString(`<text x="` + strconv.Itoa(w/2) + `" y="` + strconv.Itoa(h-14) + `" text-anchor="middle" ` +
			`fill="#9fc9b4" style="font:13px sans-serif">and ` + strconv.Itoa(more) + ` more</text>`)
	}
	b.WriteString("</svg>")
	return "![" + strconv.Itoa(n) + " hearts](data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(b.String())) + ")\n"
}
