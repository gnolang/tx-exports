package nft

const (
	gridW = 24
	gridH = 32
	half  = 12 // columns of the left half, where rows are written
)

// span is a horizontal range of pixels, x0 to x1 inclusive.
type span struct{ y, x0, x1 int }

// BuildGrid returns the pixel grid of a gnome, as 32 rows of 24 palette keys ('.' is transparent).
// Traits must be valid.
func BuildGrid(t Traits) []string {
	g := buildGrid(t)

	rows := make([]string, gridH)
	for y := 0; y < gridH; y++ {
		row := make([]byte, gridW)
		for x := 0; x < gridW; x++ {
			c := g[y*gridW+x]
			if c == 0 {
				c = '.'
			}
			row[x] = c
		}
		rows[y] = string(row)
	}
	return rows
}

// buildGrid draws all the layers of a gnome. The grid has a byte per pixel, row by row, and 0 is transparent.
func buildGrid(t Traits) []byte {
	if err := t.Validate(); err != nil {
		panic("settlers: " + err.Error())
	}

	g := make([]byte, gridW*gridH)

	draw(g, body, 19)
	if t.Beard == 0 {
		draw(g, head+headNoBeard, 13)
	} else {
		switch t.Beard {
		case 1:
			draw(g, beardLong, 19)
		case 2:
			draw(g, beardPointy, 19)
		default:
			draw(g, beardRound, 19)
		}
		draw(g, head+headBeard, 13)
	}

	if t.Glasses > 0 {
		for _, p := range glassesFrame {
			put(g, p[0], p[1], 'g')
		}
		for _, p := range glassesEyes {
			put(g, p[0], p[1], 'e')
		}
	}

	if t.HatShape == 0 {
		draw(g, hatTall, 0)
	} else {
		drawBentHat(g, t.Flip == 1)
	}
	draw(g, brim, 11)
	draw(g, boots, 28)
	return g
}

// draw draws rows, that are the left half of the sprite, starting at row y0. The right half is
// the left half mirrored, where light tones are swapped by their shaded twin.
func draw(g []byte, rows string, y0 int) {
	for i := 0; i*half < len(rows); i++ {
		y := y0 + i
		if y < 0 || y >= gridH {
			continue
		}

		row := rows[i*half : (i+1)*half]
		for j := 0; j < half; j++ {
			c := row[j]
			if c != '.' {
				g[y*gridW+j] = c
				g[y*gridW+gridW-1-j] = swapTable[c]
			}
		}
	}
}

func put(g []byte, x, y int, c byte) {
	if x >= 0 && x < gridW && y >= 0 && y < gridH {
		g[y*gridW+x] = c
	}
}

// drawBentHat draws the hat with the tip that falls to the right, or to the left when flipped.
//
// It is written without function calls (no closures or helpers), because they are the most
// expensive thing in Gno. The fill has a border of one cell, so neighbors never need a bounds check.
func drawBentHat(g []byte, flip bool) {
	const (
		rows   = coneY0 + len(coneK) + 1 // rows of the hat, one more than the cone for its outline
		stride = gridW + 2
	)
	var fill [(rows + 2) * stride]bool // No maps are used to keep it deterministic

	for i, k := range coneK {
		for x := half - k; x < half+k; x++ {
			if flip {
				fill[(coneY0+i+1)*stride+gridW-x] = true // mirrored column gridW-1-x, plus the border
			} else {
				fill[(coneY0+i+1)*stride+x+1] = true
			}
		}
	}
	for _, s := range tailSpans {
		for x := s.x0; x <= s.x1; x++ {
			if flip {
				fill[(s.y+1)*stride+gridW-x] = true
			} else {
				fill[(s.y+1)*stride+x+1] = true
			}
		}
	}

	for y := 0; y < rows; y++ {
		for x := 0; x < gridW; x++ {
			i := (y+1)*stride + x + 1
			if !fill[i] {
				continue
			}
			left, right, up, down := fill[i-1], fill[i+1], fill[i-stride], fill[i+stride]

			// Shading
			c := byte('H')
			if !left {
				if y%2 == 1 {
					c = 'h'
				}
			} else if !right || !down {
				c = 'j'
			}
			g[y*gridW+x] = c

			// Outline. It only touches pixels that are not part of the hat, so it doesn't matter
			// that it is done in the same pass as the shading.
			if !left && x > 0 {
				g[y*gridW+x-1] = 'o'
			}
			if !right && x < gridW-1 {
				g[y*gridW+x+1] = 'o'
			}
			if !up && y > 0 {
				g[(y-1)*gridW+x] = 'o'
			}
			if !down {
				g[(y+1)*gridW+x] = 'o'
			}
		}
	}
}
