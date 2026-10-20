// Package canvas is a shared 9x13 pixel-art canvas rendered as LED emoji.
//
// Draw repaints the whole grid from simple ASCII rows and records the
// caller's address as the last updater; Render shows the grid plus that
// address.
package canvas

import "strings"

const (
	gridWidth  = 9
	gridHeight = 13
)

var (
	grid       [gridHeight]string
	lastEditor address
)

func init() {
	blank := strings.Repeat(".", gridWidth)
	for r := 0; r < gridHeight; r++ {
		grid[r] = blank
	}
}

// emoji maps a palette letter to its LED emoji. Panics on an unknown letter.
func emoji(c byte) string {
	switch c {
	case '.':
		return "⬛"
	case 'R':
		return "🟥"
	case 'S':
		return "🟧"
	case 'Y':
		return "🟨"
	case 'G':
		return "🟩"
	case 'B':
		return "🟦"
	case 'W':
		return "⬜"
	case 'H':
		return "🟫"
	case 'P':
		return "🟪"
	default:
		panic("canvas: invalid pixel character '" + string(c) + "'")
	}
}

// Draw repaints the canvas from art: newline-separated ASCII rows, exactly
// 13 rows of exactly 9 characters each, using the palette
// . R S Y G B W H P (off, red, orange, yellow, green, blue, white, brown, purple).
// Records the caller as the last updater.
func Draw(cur realm, art string) {
	rows := strings.Split(art, "\n")
	if len(rows) != gridHeight {
		panic("canvas: art must have exactly 13 rows")
	}
	for _, row := range rows {
		if len(row) != gridWidth {
			panic("canvas: each row must be exactly 9 characters")
		}
		for i := 0; i < gridWidth; i++ {
			emoji(row[i]) // validates every character before committing
		}
	}
	for i, row := range rows {
		grid[i] = row
	}
	lastEditor = cur.Previous().Address()
}

// Render shows the canvas as LED emoji in a fenced code block, plus the
// address that last called Draw.
func Render(path string) string {
	var out strings.Builder
	out.WriteString("```\n")
	for r := 0; r < gridHeight; r++ {
		row := grid[r]
		for c := 0; c < gridWidth; c++ {
			out.WriteString(emoji(row[c]))
		}
		out.WriteString("\n")
	}
	out.WriteString("```\n\n")

	var zero address
	if lastEditor == zero {
		out.WriteString("*No updates yet.*\n")
	} else {
		out.WriteString("Last updated by: " + lastEditor.String() + "\n")
	}
	return out.String()
}
