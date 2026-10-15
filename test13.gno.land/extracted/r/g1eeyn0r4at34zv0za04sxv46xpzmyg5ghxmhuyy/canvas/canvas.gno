package canvas

import (
	"strings"
)

const (
	width  = 9
	height = 13
)

var (
	rows       [height]string
	lastCaller address
	hasDrawn   bool
)

func init() {
	blank := strings.Repeat(".", width)
	for i := 0; i < height; i++ {
		rows[i] = blank
	}
}

func pixel(c byte) string {
	switch c {
	case '.':
		return "⬛"
	case 'R':
		return "\U0001f7e5"
	case 'S':
		return "\U0001f7e7"
	case 'Y':
		return "\U0001f7e8"
	case 'G':
		return "\U0001f7e9"
	case 'B':
		return "\U0001f7e6"
	case 'W':
		return "⬜"
	case 'H':
		return "\U0001f7eb"
	case 'P':
		return "\U0001f7ea"
	default:
		return "⬛"
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return digits
}

// Draw repaints the canvas from ASCII rows separated by newlines.
// Each row must be exactly 9 characters using the palette:
// . R S Y G B W H P
func Draw(cur realm, art string) string {
	lines := strings.Split(strings.TrimSpace(art), "\n")
	if len(lines) != height {
		panic("canvas: expected " + itoa(height) + " rows, got " + itoa(len(lines)))
	}
	var clean [height]string
	for i, line := range lines {
		l := strings.TrimSpace(line)
		if len(l) != width {
			panic("canvas: row " + itoa(i) + " must be " + itoa(width) + " chars")
		}
		clean[i] = l
	}
	rows = clean
	hasDrawn = true
	lastCaller = cur.Previous().Address()
	return "canvas updated"
}

func Render(path string) string {
	var b strings.Builder
	b.WriteString("```\n")
	for i := 0; i < height; i++ {
		row := rows[i]
		for j := 0; j < width; j++ {
			b.WriteString(pixel(row[j]))
		}
		b.WriteString("\n")
	}
	b.WriteString("```\n\n")
	if !hasDrawn {
		b.WriteString("*no updates yet*\n")
	} else {
		b.WriteString("last updated by: " + lastCaller.String() + "\n")
	}
	return b.String()
}
