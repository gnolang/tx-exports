package canvas

import "strings"

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

// Draw repaints the canvas from height rows of width ASCII letters each.
func Draw(cur realm, art string) {
	lines := strings.Split(strings.TrimSpace(art), "\n")
	if len(lines) != height {
		panic("art must have exactly 13 rows")
	}
	for i, line := range lines {
		if len(line) != width {
			panic("each row must have exactly 9 characters")
		}
		grid[i] = line
	}
	lastUpdater = cur.Previous().Address()
}

func emoji(c byte) string {
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

func Render(path string) string {
	var sb strings.Builder
	sb.WriteString("```\n")
	for _, row := range grid {
		for i := 0; i < len(row); i++ {
			sb.WriteString(emoji(row[i]))
		}
		sb.WriteString("\n")
	}
	sb.WriteString("```\n\n")
	if lastUpdater == "" {
		sb.WriteString("Last updated by: (no updates yet)\n")
	} else {
		sb.WriteString("Last updated by: " + lastUpdater.String() + "\n")
	}
	return sb.String()
}
