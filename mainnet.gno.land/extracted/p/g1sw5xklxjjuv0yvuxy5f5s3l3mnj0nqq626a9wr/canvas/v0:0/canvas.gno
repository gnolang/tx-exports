// Package canvas is a fixed-size, 16-color pixel grid.
//
// It holds no chain state and knows nothing about payments: the realm
// gno.land/r/g1sw5xklxjjuv0yvuxy5f5s3l3mnj0nqq626a9wr/million/v0 wraps it with pricing and access control.
//
// Storage layout: one []byte per row, allocated on first paint. A row that
// was never painted is nil and costs nothing. Each byte holds a palette
// index; Blank (0) means "never painted".
package canvas

import (
	"errors"
	"strconv"
	"strings"
)

const (
	// Blank is the color of a pixel nobody painted. It cannot be painted.
	Blank byte = 0
	// MaxColor is the highest valid palette index.
	MaxColor byte = 15
	// MaxSide bounds width and height so x*y fits comfortably in an int.
	MaxSide = 10000
)

// Palette maps a color index to its CSS hex value. Index 0 is Blank and is
// rendered as white by clients.
var Palette = [MaxColor + 1]string{
	"#ffffff", // 0 blank
	"#ffffff", // 1 white
	"#e4e4e4", // 2 light gray
	"#888888", // 3 gray
	"#222222", // 4 black
	"#ffa7d1", // 5 pink
	"#e50000", // 6 red
	"#e59500", // 7 orange
	"#a06a42", // 8 brown
	"#e5d900", // 9 yellow
	"#94e044", // 10 lime
	"#02be01", // 11 green
	"#00d3dd", // 12 cyan
	"#0083c7", // 13 blue
	"#cf6ee4", // 14 magenta
	"#820080", // 15 purple
}

var (
	ErrOutOfRange   = errors.New("canvas: pixel out of range")
	ErrInvalidColor = errors.New("canvas: color must be between 1 and 15")
	ErrBadPixel     = errors.New("canvas: pixel must be x,y,color")
)

// Pixel is one paint request.
type Pixel struct {
	X, Y  int
	Color byte
}

// Canvas is a width x height grid of palette indexes.
type Canvas struct {
	width, height int
	rows          [][]byte
	painted       int
}

// New returns an empty canvas. It panics on a non-positive or oversized side.
func New(width, height int) *Canvas {
	if width <= 0 || height <= 0 || width > MaxSide || height > MaxSide {
		panic("canvas: width and height must be between 1 and " + strconv.Itoa(MaxSide))
	}
	return &Canvas{
		width:  width,
		height: height,
		rows:   make([][]byte, height),
	}
}

func (c *Canvas) Width() int  { return c.width }
func (c *Canvas) Height() int { return c.height }

// Painted is the number of pixels that are not Blank.
func (c *Canvas) Painted() int { return c.painted }

// Check reports whether p can be painted on this canvas.
func (c *Canvas) Check(p Pixel) error {
	if p.X < 0 || p.Y < 0 || p.X >= c.width || p.Y >= c.height {
		return ErrOutOfRange
	}
	if p.Color == Blank || p.Color > MaxColor {
		return ErrInvalidColor
	}
	return nil
}

// Get returns the color at (x, y). Out-of-range coordinates panic.
func (c *Canvas) Get(x, y int) byte {
	if x < 0 || y < 0 || x >= c.width || y >= c.height {
		panic(ErrOutOfRange)
	}
	row := c.rows[y]
	if row == nil {
		return Blank
	}
	return row[x]
}

// Set paints p. It panics when Check(p) fails.
func (c *Canvas) Set(p Pixel) {
	if err := c.Check(p); err != nil {
		panic(err)
	}
	row := c.rows[p.Y]
	if row == nil {
		row = make([]byte, c.width)
		c.rows[p.Y] = row
	}
	if row[p.X] == Blank {
		c.painted++
	}
	row[p.X] = p.Color
}

// Rows encodes rows [from, to) as one hex digit per pixel, row after row,
// with no separator. Clients slice it with the known width.
func (c *Canvas) Rows(from, to int) string {
	if from < 0 || to > c.height || from > to {
		panic(ErrOutOfRange)
	}
	var sb strings.Builder
	sb.Grow((to - from) * c.width)
	for y := from; y < to; y++ {
		row := c.rows[y]
		if row == nil {
			for x := 0; x < c.width; x++ {
				sb.WriteByte('0')
			}
			continue
		}
		for _, color := range row {
			sb.WriteByte(hexDigit(color))
		}
	}
	return sb.String()
}

// ParsePixels decodes "x,y,color;x,y,color;...". A trailing ';' is allowed.
// It validates the syntax and the color range but not the coordinates,
// which depend on the canvas: call Check for that.
func ParsePixels(s string) ([]Pixel, error) {
	s = strings.TrimSuffix(s, ";")
	if s == "" {
		return nil, ErrBadPixel
	}
	parts := strings.Split(s, ";")
	pixels := make([]Pixel, 0, len(parts))
	for _, part := range parts {
		fields := strings.Split(part, ",")
		if len(fields) != 3 {
			return nil, ErrBadPixel
		}
		x, err := strconv.Atoi(fields[0])
		if err != nil {
			return nil, ErrBadPixel
		}
		y, err := strconv.Atoi(fields[1])
		if err != nil {
			return nil, ErrBadPixel
		}
		color, err := ParseColor(fields[2])
		if err != nil {
			return nil, err
		}
		pixels = append(pixels, Pixel{X: x, Y: y, Color: color})
	}
	return pixels, nil
}

// ParseColor converts a decimal color index, rejecting Blank.
func ParseColor(s string) (byte, error) {
	n, err := strconv.Atoi(s)
	if err != nil || n <= int(Blank) || n > int(MaxColor) {
		return 0, ErrInvalidColor
	}
	return byte(n), nil
}

// Encode is the inverse of ParsePixels.
func Encode(pixels []Pixel) string {
	var sb strings.Builder
	for i, p := range pixels {
		if i > 0 {
			sb.WriteByte(';')
		}
		sb.WriteString(strconv.Itoa(p.X))
		sb.WriteByte(',')
		sb.WriteString(strconv.Itoa(p.Y))
		sb.WriteByte(',')
		sb.WriteString(strconv.Itoa(int(p.Color)))
	}
	return sb.String()
}

func hexDigit(v byte) byte {
	if v < 10 {
		return '0' + v
	}
	return 'a' + v - 10
}
