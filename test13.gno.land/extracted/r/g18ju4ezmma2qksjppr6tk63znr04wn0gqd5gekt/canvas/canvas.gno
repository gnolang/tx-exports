// Package canvas is a 9x13 pixel-art LED canvas. Draw repaints it from
// simple ASCII rows and Render shows the grid plus who last painted it.
package canvas

import (
	"strings"
)

const (
	rows = 9
	cols = 13
)

// led maps an ASCII pixel code to its emoji.
var led = map[byte]string{
	'.': "⬛", // off
	'R': "🟥",
	'O': "🟧",
	'Y': "🟨",
	'G': "🟩",
	'B': "🟦",
	'P': "🟪",
	'W': "⬜",
	'N': "🟫",
}

var (
	grid        [rows]string // each entry is `cols` ASCII pixel codes
	lastPainter address
	painted     bool
)

func init() {
	blank := strings.Repeat(".", cols)
	for i := 0; i < rows; i++ {
		grid[i] = blank
	}
}

// Draw repaints the canvas from ASCII art: `rows` newline-separated rows,
// each exactly 13 characters from the set ".ROYGBPWN". Records the caller
// as the canvas's last painter.
func Draw(cur realm, art string) {
	newGrid := parseArt(art)
	grid = newGrid
	lastPainter = cur.Previous().Address()
	painted = true
}

// parseArt validates ASCII art into a grid, panicking on any malformed input.
func parseArt(art string) [rows]string {
	lines := strings.Split(art, "\n")
	if len(lines) != rows {
		panic("canvas: need exactly 9 rows")
	}
	for _, line := range lines {
		if len(line) != cols {
			panic("canvas: each row must be exactly 13 characters")
		}
		for i := 0; i < len(line); i++ {
			if _, ok := led[line[i]]; !ok {
				panic("canvas: unknown pixel code '" + string(line[i]) + "'")
			}
		}
	}

	var newGrid [rows]string
	copy(newGrid[:], lines)
	return newGrid
}

// Render draws the canvas as LED-emoji pixels and names the last painter.
func Render(_ string) string {
	var out strings.Builder
	out.WriteString("# Canvas\n\n```\n")
	for i := 0; i < rows; i++ {
		row := grid[i]
		for j := 0; j < len(row); j++ {
			out.WriteString(led[row[j]])
		}
		out.WriteString("\n")
	}
	out.WriteString("```\n\n")
	if painted {
		out.WriteString("Last updated by: " + lastPainter.String() + "\n")
	} else {
		out.WriteString("Blank canvas — no one has painted yet.\n")
	}
	return out.String()
}
