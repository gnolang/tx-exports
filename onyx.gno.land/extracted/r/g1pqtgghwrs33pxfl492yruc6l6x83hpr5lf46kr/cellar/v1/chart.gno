package cellar

import (
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/g1pqtgghwrs33pxfl492yruc6l6x83hpr5lf46kr/cellar/formula/v1"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const maxPoints = 24

// chart draws two lines of cells, one for labels and one for values.
type chart struct {
	kind   string // "bar" or "line"
	title  string
	labels formula.Range
	values formula.Range
}

func isLine(a formula.Range) bool { return a.Cols() == 1 || a.Rows() == 1 }

// line returns the values of an area of one row or one column.
func (s *sheet) line(c *formula.Calc, a formula.Range) []formula.Value {
	out := make([]formula.Value, 0, a.Size())
	for row := a.A.Row; row <= a.B.Row; row++ {
		for col := a.A.Col; col <= a.B.Col; col++ {
			out = append(out, c.Value(s.name, col, row))
		}
	}
	return out
}

// markdown returns the chart as an image. Cells that are not numbers are left
// out, and so are negative numbers in a bar chart.
func (ch chart) markdown(s *sheet, c *formula.Calc) string {
	labels, values := s.line(c, ch.labels), s.line(c, ch.values)
	var names []string
	var nums []formula.Num
	for i, v := range values {
		n, ok := v.Num()
		if !ok || n < 0 && ch.kind == "bar" {
			continue
		}
		names = append(names, labels[i].String())
		nums = append(nums, n)
	}
	if len(nums) == 0 {
		return "_" + sanitize.InlineText(ch.title) + ": nothing to draw yet._\n"
	}
	body, height := "", 0
	if ch.kind == "bar" {
		body, height = bars(names, nums)
	} else {
		body, height = curve(names, nums)
	}
	svg := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 ` + strconv.Itoa(height) +
		`" font-family="sans-serif" font-size="14" fill="` + ink + `">` + body + `</svg>`
	return "![" + sanitize.InlineText(ch.title) + "](data:image/svg+xml;base64," +
		base64.StdEncoding.EncodeToString([]byte(svg)) + ")\n"
}

// Colors that can be read on a light and on a dark page.
const (
	ink    = "#7d7d7d"
	accent = "#2f9e6e"
	track  = "#7d7d7d"
)

func bars(names []string, nums []formula.Num) (string, int) {
	max := formula.Num(1)
	for _, n := range nums {
		if n > max {
			max = n
		}
	}
	out := ""
	for i, n := range nums {
		y := 8 + i*34
		w := scale(n, max, 330)
		out += text(150, y+18, "end", clip(names[i], 18)) +
			`<rect x="160" y="` + strconv.Itoa(y) + `" width="330" height="24" rx="4" fill="` + track + `" fill-opacity=".15"/>` +
			`<rect x="160" y="` + strconv.Itoa(y) + `" width="` + strconv.Itoa(w) + `" height="24" rx="4" fill="` + accent + `"/>` +
			text(500, y+18, "start", clip(n.String(), 13))
	}
	return out, 16 + len(nums)*34
}

func curve(names []string, nums []formula.Num) (string, int) {
	lo, hi := nums[0], nums[0]
	for _, n := range nums {
		if n < lo {
			lo = n
		}
		if n > hi {
			hi = n
		}
	}
	span, ok := formula.Sub(hi, lo)
	if !ok || span == 0 {
		span = 1
	}
	out, points := "", ""
	for i, n := range nums {
		x := 300
		if len(nums) > 1 {
			x = 40 + i*520/(len(nums)-1)
		}
		y := 170 - scale(n-lo, span, 140)
		p := strconv.Itoa(x) + "," + strconv.Itoa(y)
		points += p + " "
		out += `<circle cx="` + strconv.Itoa(x) + `" cy="` + strconv.Itoa(y) + `" r="4" fill="` + accent + `"/>`
		// Label the ends and, when there is room, every point.
		if len(nums) <= 8 || i == 0 || i == len(nums)-1 {
			out += text(x, 198, "middle", clip(names[i], 10)) + text(x, y-10, "middle", clip(n.String(), 10))
		}
	}
	line := `<polyline points="` + points + `" fill="none" stroke="` + accent + `" stroke-width="3"/>`
	return line + out, 210
}

// scale maps n in [0, max] to [0, size].
func scale(n, max formula.Num, size int) int {
	r, ok := formula.Div(n, max)
	if !ok {
		return 0
	}
	return int(int64(r) * int64(size) / int64(formula.Unit))
}

func text(x, y int, anchor, s string) string {
	return `<text x="` + strconv.Itoa(x) + `" y="` + strconv.Itoa(y) + `" text-anchor="` + anchor + `">` +
		escape(s) + `</text>`
}

// clip shortens s to n characters.
func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	count, cut := 0, 0
	for i := range s {
		if count == n-1 {
			cut = i
		}
		if count++; count > n {
			return s[:cut] + "…"
		}
	}
	return s
}

// escape makes s safe inside SVG text.
func escape(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	return strings.ReplaceAll(s, ">", "&gt;")
}
