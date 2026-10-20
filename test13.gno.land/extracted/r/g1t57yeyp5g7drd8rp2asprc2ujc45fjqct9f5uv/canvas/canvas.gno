// Package canvas is a 9x13 pixel-art board rendered as LED-emoji pixels.
//
// Draw repaints the whole grid from a simple ASCII sketch and records
// who painted it. The canvas starts blank (all pixels off).
package canvas

import "strings"

const (
	numRows = 9
	numCols = 13
)

var (
	grid        [numRows]string
	lastUpdater address
	hasUpdater  bool
)

func init() {
	blank := strings.Repeat(".", numCols)
	for i := range grid {
		grid[i] = blank
	}
}

// Draw repaints the canvas from art: exactly 9 rows separated by
// newlines, each row exactly 13 characters wide. Records the caller
// as the canvas's last updater.
//
// Character legend (unrecognized characters render as off):
//
//	.  off      W  white    R  red     O  orange
//	Y  yellow   G  green    B  blue    P  purple
//	N  brown    K  black
func Draw(cur realm, art string) {
	lines := strings.Split(strings.TrimRight(art, "\n"), "\n")
	if len(lines) != numRows {
		panic("art must have exactly 9 rows")
	}
	for _, line := range lines {
		if len(line) != numCols {
			panic("each row must be exactly 13 characters wide")
		}
	}
	for i, line := range lines {
		grid[i] = line
	}
	lastUpdater = cur.Previous().Address()
	hasUpdater = true
}

func pixel(c byte) string {
	switch c {
	case 'W':
		return "⬜"
	case 'R':
		return "🟥"
	case 'O':
		return "🟧"
	case 'Y':
		return "🟨"
	case 'G':
		return "🟩"
	case 'B':
		return "🟦"
	case 'P':
		return "🟪"
	case 'N':
		return "🟫"
	default:
		return "⬛"
	}
}

// Render draws the current canvas as a fenced grid of LED-emoji pixels
// and reports who last updated it.
func Render(_ string) string {
	var out strings.Builder
	out.WriteString("# canvas\n\n```\n")
	for _, row := range grid {
		for i := 0; i < len(row); i++ {
			out.WriteString(pixel(row[i]))
		}
		out.WriteString("\n")
	}
	out.WriteString("```\n\n")
	if hasUpdater {
		out.WriteString("last updated by: `" + lastUpdater.String() + "`\n")
	} else {
		out.WriteString("last updated by: _(nobody yet, canvas is blank)_\n")
	}
	return out.String()
}
