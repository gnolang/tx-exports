package connect4

const (
	cols = 7
	rows = 6
)

// board is indexed [column][row]; row 0 is the bottom. 0 = empty, 1/2 = player.
type board [cols][rows]byte

// drop places piece p in column c (0-based) and returns its row, or -1 if the column is full.
func (b *board) drop(c int, p byte) int {
	for r := 0; r < rows; r++ {
		if b[c][r] == 0 {
			b[c][r] = p
			return r
		}
	}
	return -1
}

// wins reports whether the piece at (c, r) is part of four in a row.
func (b *board) wins(c, r int) bool { return b.winLine(c, r) != nil }

// winLine returns the cells of the four-or-more line through (c, r), in order
// along the line, or nil if the piece there completes none.
func (b *board) winLine(c, r int) [][2]int {
	p := b[c][r]
	for _, d := range [4][2]int{{1, 0}, {0, 1}, {1, 1}, {1, -1}} {
		back := b.count(c, r, -d[0], -d[1], p)
		n := 1 + back + b.count(c, r, d[0], d[1], p)
		if n >= 4 {
			line := make([][2]int, n)
			for i := range line {
				k := i - back
				line[i] = [2]int{c + k*d[0], r + k*d[1]}
			}
			return line
		}
	}
	return nil
}

// count returns how many consecutive p pieces follow (c, r) in direction (dc, dr).
func (b *board) count(c, r, dc, dr int, p byte) int {
	n := 0
	for {
		c, r = c+dc, r+dr
		if c < 0 || c >= cols || r < 0 || r >= rows || b[c][r] != p {
			return n
		}
		n++
	}
}
