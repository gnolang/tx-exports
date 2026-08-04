// Package canvas is a 9x13 pixel-art board. Draw repaints it from ASCII
// rows (one palette letter per pixel) and records the calling address;
// Render shows the board as LED emoji plus who painted it last.
package canvas

import (
	"strconv"
	"strings"

	"chain"
)

const (
	width  = 9
	height = 13
)

var palette = map[byte]string{
	'.': "⬛",
	'R': "🟥",
	'S': "🟧",
	'Y': "🟨",
	'G': "🟩",
	'B': "🟦",
	'W': "⬜",
	'H': "🟫",
	'P': "🟪",
}

var (
	grid      [height]string
	lastAddr  string
	lastPkg   string
	updateNum int
)

func init() {
	blankRow := strings.Repeat(".", width)
	for i := range grid {
		grid[i] = blankRow
	}
}

// Draw repaints the canvas from `art`: height rows of width palette
// letters, separated by newlines. Panics on any malformed row or
// unknown letter, leaving the previous canvas untouched.
func Draw(cur realm, art string) {
	rows := strings.Split(strings.TrimSpace(art), "\n")
	if len(rows) != height {
		panic("canvas: art must have exactly " + strconv.Itoa(height) + " rows, got " + strconv.Itoa(len(rows)))
	}

	var next [height]string
	for i, row := range rows {
		if len(row) != width {
			panic("canvas: row " + strconv.Itoa(i) + " must have exactly " + strconv.Itoa(width) + " characters")
		}
		for j := 0; j < len(row); j++ {
			if _, ok := palette[row[j]]; !ok {
				panic("canvas: unknown palette letter " + string(row[j]) + " at row " + strconv.Itoa(i))
			}
		}
		next[i] = row
	}

	grid = next
	lastAddr = cur.Previous().Address().String()
	lastPkg = cur.Previous().PkgPath()
	updateNum++

	chain.Emit("Draw", "by", lastAddr, "n", strconv.Itoa(updateNum))
}

// Render shows the current canvas as an LED-emoji grid in a fenced code
// block, plus the address that performed the last update.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString("```\n")
	for _, row := range grid {
		for i := 0; i < len(row); i++ {
			b.WriteString(palette[row[i]])
		}
		b.WriteString("\n")
	}
	b.WriteString("```\n")

	if lastAddr == "" {
		b.WriteString("\nNo updates yet — canvas is blank.\n")
	} else {
		b.WriteString("\nLast updated by: `" + lastAddr + "`")
		if lastPkg != "" {
			b.WriteString(" (via `" + lastPkg + "`)")
		}
		b.WriteString(" — update #" + strconv.Itoa(updateNum) + "\n")
	}
	return b.String()
}
