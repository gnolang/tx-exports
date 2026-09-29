package gno4

import (
	"strings"

	"gno.land/p/nt/svg/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Board geometry, in SVG user units. Everything else is derived, so changing
// cell changes the whole drawing and nothing goes out of step.
const (
	pad  = 10
	cell = 74
	hole = 30

	svgW = Cols*cell + 2*pad
	svgH = Rows*cell + 2*pad
	labY = svgH + 22
)

// The palette. Fixed hex rather than CSS variables: gnoweb renders the SVG
// inside a data URI, which is its own document and inherits nothing from the
// page, so a theme-aware colour would resolve to nothing at all.
const (
	colBoard  = "#1d4ed8"
	colHole   = "#f8fafc"
	colRed    = "#ef4444"
	colYellow = "#facc15"
	colLabel  = "#64748b"
	colWin    = "#0f172a"
)

// SVG returns the board as standalone <svg> markup.
//
// It is a drawing of a position, not a control: there is no script, no link
// and no interactivity, because gnoweb serves this through a data URI and
// would not run any of it. The clickable column menu is the realm's job, as
// ordinary markdown links next to the image.
func (b *Board) SVG() string { return b.canvas().String() }

// Image returns the board as a markdown image, ready to drop into a realm's
// Render output. The SVG travels inline as a data URI, which gnoweb allows for
// image/svg+xml specifically, so the board needs no hosting and no asset
// pipeline: there is nothing to go missing later, and no storage is spent on
// it because it is drawn at render time rather than stored.
func (b *Board) Image(alt string) string { return b.canvas().Render(alt) }

func (b *Board) canvas() *svg.Canvas {
	c := svg.NewCanvas(svgW, svgH+30).WithViewBox(0, 0, svgW, svgH+30)
	c.AddStyle(".win", "stroke:"+colWin+";stroke-width:5")
	c.AddStyle(".last", "stroke:#ffffff;stroke-width:4")
	c.AddStyle(".lab", "font:600 22px system-ui,sans-serif;text-anchor:middle")

	c.Append(svg.NewRectangle(0, 0, svgW, svgH, colBoard))

	last := -1
	if n := len(b.moves); n > 0 {
		lastCol := b.moves[n-1]
		last = idx(lastCol, b.Height(lastCol)-1)
	}
	win := b.line

	for row := Rows - 1; row >= 0; row-- {
		for col := 0; col < Cols; col++ {
			cx := pad + col*cell + cell/2
			cy := pad + (Rows-1-row)*cell + cell/2
			fill := colHole
			switch b.At(col, row) {
			case Red:
				fill = colRed
			case Yellow:
				fill = colYellow
			}
			disc := svg.NewCircle(cx, cy, hole, fill)
			switch {
			case contains(win, idx(col, row)):
				disc.WithClass("win")
			case idx(col, row) == last:
				disc.WithClass("last")
			}
			c.Append(disc)
		}
	}

	for col := 0; col < Cols; col++ {
		x := pad + col*cell + cell/2
		c.Append(svg.NewText(x, labY, ufmt.Sprintf("%d", col+1), colLabel).WithClass("lab"))
	}

	return c
}

// Emoji returns the board as seven columns of coloured squares, top row first.
//
// The text fallback, for the places an image cannot go: a chain event, a
// terminal, a commit message, a diff. It is also what makes the whole package
// legible in a test failure.
func (b *Board) Emoji() string {
	var sb strings.Builder
	for row := Rows - 1; row >= 0; row-- {
		for col := 0; col < Cols; col++ {
			switch b.At(col, row) {
			case Red:
				sb.WriteString("🔴")
			case Yellow:
				sb.WriteString("🟡")
			default:
				sb.WriteString("⚫")
			}
		}
		sb.WriteByte('\n')
	}
	return sb.String()
}
