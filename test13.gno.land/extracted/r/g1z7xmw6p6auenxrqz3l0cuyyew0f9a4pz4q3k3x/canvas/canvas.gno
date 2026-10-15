package canvas

import (
	"chain"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

const (
	width  = 9
	height = 13
)

var (
	grid        [height]string
	lastUpdater address
)

func init() {
	blank := strings.Repeat(".", width)
	for i := 0; i < height; i++ {
		grid[i] = blank
	}
}

func pixel(c byte) string {
	switch c {
	case 'R':
		return "\U0001F7E5"
	case 'S':
		return "\U0001F7E7"
	case 'Y':
		return "\U0001F7E8"
	case 'G':
		return "\U0001F7E9"
	case 'B':
		return "\U0001F7E6"
	case 'W':
		return "⬜"
	case 'H':
		return "\U0001F7EB"
	case 'P':
		return "\U0001F7EA"
	default:
		return "⬛"
	}
}

// Draw repaints the canvas from `height` newline-separated rows of `width`
// ASCII letters each, and records the caller as the last updater.
func Draw(cur realm, art string) {
	lines := strings.Split(strings.TrimSpace(art), "\n")
	if len(lines) != height {
		panic("canvas: art must have exactly 13 rows")
	}

	var next [height]string
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if len(line) != width {
			panic("canvas: each row must have exactly 9 characters")
		}
		next[i] = line
	}

	grid = next
	lastUpdater = cur.Previous().Address()
	chain.Emit("Draw", "by", lastUpdater.String())
}

func Render(path string) string {
	out := "```\n"
	for _, row := range grid {
		for i := 0; i < len(row); i++ {
			out += pixel(row[i])
		}
		out += "\n"
	}
	out += "```\n\n"

	if lastUpdater == "" {
		out += "_blank canvas — no updates yet_"
	} else {
		out += ufmt.Sprintf("Last updated by: `%s`", lastUpdater.String())
	}

	return out
}
