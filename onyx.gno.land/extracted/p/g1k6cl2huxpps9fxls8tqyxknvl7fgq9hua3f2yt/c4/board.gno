package c4

// Package c4 holds the rules of four-in-a-row on a 7x6 board — nothing about
// players, purses or pages. A disc dropped into a column falls to the lowest
// free row; four of one colour in a line (horizontal, vertical or either
// diagonal) wins; a full board with no line is a draw.
//
// The board is a value: Play returns a new board and never mutates the one it
// was given, so a realm can keep history or replay a game without copying by
// hand. Every function here is pure, which is why the realm can be tested
// against known games move by move.

const (
	// Cols and Rows are the board's size.
	Cols = 7
	Rows = 6

	// Empty is an unoccupied cell; Red and Yellow are the two colours. Red
	// moves first.
	Empty  uint8 = 0
	Red    uint8 = 1
	Yellow uint8 = 2

	// WinLength is how many discs in a line win the game.
	WinLength = 4
)

// Board is the 42 cells, row-major from the top: index = row*Cols + col.
type Board struct {
	Cells [Rows * Cols]uint8
}

// New returns an empty board.
func New() Board {
	return Board{}
}

// Other returns the colour that moves after c.
func Other(c uint8) uint8 {
	if c == Red {
		return Yellow
	}
	return Red
}

// Name returns a short word for a colour, used by pages and JSON.
func Name(c uint8) string {
	if c == Red {
		return "red"
	}
	if c == Yellow {
		return "yellow"
	}
	return "empty"
}

// ValidColour reports whether c is one of the two disc colours.
func ValidColour(c uint8) bool {
	return c == Red || c == Yellow
}

// At reads a cell. Out-of-range coordinates read as Empty, which keeps the
// line scan below from needing bounds checks at every step.
func (b Board) At(row, col int) uint8 {
	if row < 0 || row >= Rows || col < 0 || col >= Cols {
		return Empty
	}
	return b.Cells[row*Cols+col]
}

// LandRow is the row a disc dropped into col would rest on, or -1 when the
// column is full or out of range.
func (b Board) LandRow(col int) int {
	if col < 0 || col >= Cols {
		return -1
	}
	for row := Rows - 1; row >= 0; row-- {
		if b.At(row, col) == Empty {
			return row
		}
	}
	return -1
}

// Legal returns the columns a disc can still be dropped into, left to right.
func (b Board) Legal() []int {
	out := []int{}
	for col := 0; col < Cols; col++ {
		if b.LandRow(col) >= 0 {
			out = append(out, col)
		}
	}
	return out
}

// Full reports whether every column is full.
func (b Board) Full() bool {
	for col := 0; col < Cols; col++ {
		if b.LandRow(col) >= 0 {
			return false
		}
	}
	return true
}

// Play drops a disc of colour cell into column col and returns the new board,
// the row it landed on, and an error string ("" on success). The receiver is
// untouched.
func (b Board) Play(cell uint8, col int) (Board, int, string) {
	if !ValidColour(cell) {
		return b, -1, "colour must be red or yellow"
	}
	if col < 0 || col >= Cols {
		return b, -1, "column must be between 1 and 7"
	}
	row := b.LandRow(col)
	if row < 0 {
		return b, -1, "column is full"
	}
	next := Board{}
	next.Cells = b.Cells
	next.Cells[row*Cols+col] = cell
	return next, row, ""
}

// Winner returns the colour with four in a line, the indices of those four
// cells, and whether there is one. Only the earliest line in a top-left scan
// is reported, which is all a page needs to highlight.
func (b Board) Winner() (uint8, []int, bool) {
	for row := 0; row < Rows; row++ {
		for col := 0; col < Cols; col++ {
			cell := b.At(row, col)
			if cell == Empty {
				continue
			}
			for d := 0; d < len(dirs); d++ {
				dr := dirs[d][0]
				dc := dirs[d][1]
				if b.At(row+dr, col+dc) != cell {
					continue
				}
				if b.At(row+2*dr, col+2*dc) != cell || b.At(row+3*dr, col+3*dc) != cell {
					continue
				}
				line := []int{
					row*Cols + col,
					(row+dr)*Cols + col + dc,
					(row+2*dr)*Cols + col + 2*dc,
					(row+3*dr)*Cols + col + 3*dc,
				}
				return cell, line, true
			}
		}
	}
	return Empty, []int{}, false
}

// HasWinner is Winner without the line.
func (b Board) HasWinner() bool {
	_, _, ok := b.Winner()
	return ok
}

// String encodes the board as 42 characters, row-major from the top, with
// '0' empty, '1' red and '2' yellow. It is the wire form the web UI reads.
func (b Board) String() string {
	out := make([]byte, 0, Rows*Cols)
	for i := 0; i < Rows*Cols; i++ {
		c := b.Cells[i]
		if c > Yellow {
			c = Empty
		}
		out = append(out, byte('0'+c))
	}
	return string(out)
}

// Parse reads the form String writes. Anything that is not 42 cells of 0/1/2
// is refused rather than guessed at.
func Parse(s string) (Board, string) {
	if len(s) != Rows*Cols {
		return New(), "board must be 42 characters"
	}
	b := Board{}
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '0':
			b.Cells[i] = Empty
		case '1':
			b.Cells[i] = Red
		case '2':
			b.Cells[i] = Yellow
		default:
			return New(), "board cells must be 0, 1 or 2"
		}
	}
	return b, ""
}

// dirs are the four line directions that can win: across, down, and the two
// diagonals. Reading along (0,1) and (1,0) is enough for the reverse
// directions too, because the scan starts at both ends of a line.
var dirs = [4][2]int{
	{0, 1},
	{1, 0},
	{1, 1},
	{1, -1},
}
