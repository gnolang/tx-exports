// Package gno4 is a Connect Four engine: the rules, and nothing else.
//
// It imports no chain package, takes no address and reads no height, so it is
// unit-testable with no node and a realm that uses it stays thin. Everything a
// caller needs to know about a position is derivable from a [Board], and a
// whole game round-trips through a string of at most 42 digits ([Board.Encode]).
//
// Live demo: [r/moul/gno4](/r/moul/gno4).
package gno4

import "errors"

// Cols and Rows are the standard board. They are constants rather than fields
// because every rule below, the win scan in particular, is written against
// them; a variable board is a different package, not a flag on this one.
const (
	Cols = 7
	Rows = 6
)

// Disc identifies whose disc occupies a cell. Empty is the zero value, so a
// freshly allocated Board is a legal empty board with no constructor call.
type Disc byte

const (
	Empty  Disc = 0
	Red    Disc = 1
	Yellow Disc = 2
)

// Other returns the opponent of d, and Empty for Empty.
func (d Disc) Other() Disc {
	switch d {
	case Red:
		return Yellow
	case Yellow:
		return Red
	}
	return Empty
}

func (d Disc) String() string {
	switch d {
	case Red:
		return "red"
	case Yellow:
		return "yellow"
	}
	return "empty"
}

var (
	ErrColumnRange = errors.New("gno4: column out of range")
	ErrColumnFull  = errors.New("gno4: column is full")
	ErrGameOver    = errors.New("gno4: game is over")
	ErrBadEncoding = errors.New("gno4: not a valid game encoding")
)

// Board is a position plus the moves that produced it.
//
// The winner and the winning line are computed once, by the Drop that creates
// them, and stored. A realm renders a finished game far more often than it
// plays a move, and rescanning 69 lines on every Render is gas spent to learn
// something the board already knew.
type Board struct {
	cells  [Cols * Rows]Disc
	moves  []int
	winner Disc
	line   []int
}

// New returns an empty board. Red moves first.
func New() *Board { return &Board{} }

func idx(col, row int) int { return row*Cols + col }

// At returns the disc at (col, row), counting rows from the bottom. Out of
// range is Empty rather than a panic: At is called from render loops that walk
// past the edge on purpose, and a Render that panics is a permanently
// unreadable page.
func (b *Board) At(col, row int) Disc {
	if col < 0 || col >= Cols || row < 0 || row >= Rows {
		return Empty
	}
	return b.cells[idx(col, row)]
}

// Turn returns whose move it is. Red on even move counts, Yellow on odd.
func (b *Board) Turn() Disc {
	if len(b.moves)%2 == 0 {
		return Red
	}
	return Yellow
}

// MoveCount returns how many discs are on the board.
func (b *Board) MoveCount() int { return len(b.moves) }

// Moves returns a copy of the move list, as zero-based column indexes.
func (b *Board) Moves() []int {
	out := make([]int, len(b.moves))
	copy(out, b.moves)
	return out
}

// Height returns how many discs are stacked in col.
func (b *Board) Height(col int) int {
	if col < 0 || col >= Cols {
		return 0
	}
	n := 0
	for row := 0; row < Rows; row++ {
		if b.cells[idx(col, row)] == Empty {
			break
		}
		n++
	}
	return n
}

// Winner returns the disc that made four in a row, or Empty.
func (b *Board) Winner() Disc { return b.winner }

// Line returns the four cell indexes that won, or nil. An index is
// row*Cols+col, the same order [Board.At] uses.
func (b *Board) Line() []int {
	out := make([]int, len(b.line))
	copy(out, b.line)
	return out
}

// Full reports whether all 42 cells are taken.
func (b *Board) Full() bool { return len(b.moves) == Cols*Rows }

// Over reports whether the game is decided: someone won, or the board filled.
func (b *Board) Over() bool { return b.winner != Empty || b.Full() }

// Draw reports whether the board filled with no winner.
func (b *Board) Draw() bool { return b.winner == Empty && b.Full() }

// CanDrop reports whether the current player may play col right now.
func (b *Board) CanDrop(col int) bool {
	return !b.Over() && col >= 0 && col < Cols && b.Height(col) < Rows
}

// Legal returns every column the current player may play. Empty once the game
// is over, which is what makes it safe to render as the move menu.
func (b *Board) Legal() []int {
	out := []int{}
	if b.Over() {
		return out
	}
	for col := 0; col < Cols; col++ {
		if b.Height(col) < Rows {
			out = append(out, col)
		}
	}
	return out
}

// Drop plays the current player's disc into col and returns the row it landed
// on. It is the only method that mutates a Board, so every illegal state this
// package could reach is refused in one place.
func (b *Board) Drop(col int) (int, error) {
	if b.Over() {
		return 0, ErrGameOver
	}
	if col < 0 || col >= Cols {
		return 0, ErrColumnRange
	}
	row := b.Height(col)
	if row >= Rows {
		return 0, ErrColumnFull
	}
	d := b.Turn()
	b.cells[idx(col, row)] = d
	b.moves = append(b.moves, col)
	if line := b.scan(col, row, d); line != nil {
		b.winner = d
		b.line = line
	}
	return row, nil
}

// Clone returns an independent copy. Callers that search (a hint, a bot) mutate
// a clone; a Board handed out by a realm is never a scratch pad.
func (b *Board) Clone() *Board {
	c := &Board{cells: b.cells, winner: b.winner}
	c.moves = make([]int, len(b.moves))
	copy(c.moves, b.moves)
	c.line = make([]int, len(b.line))
	copy(c.line, b.line)
	return c
}

// WinningMove returns a column where d wins on the spot, or -1.
//
// It is deliberately one ply deep. That covers the two things a player wants
// from a board they are looking at ("can I win now", "can they win now, so I
// must block") and costs seven clones; a real search belongs off-chain, in the
// front-end, where nobody pays gas to think.
func (b *Board) WinningMove(d Disc) int {
	if b.Over() {
		return -1
	}
	for col := 0; col < Cols; col++ {
		row := b.Height(col)
		if row >= Rows {
			continue
		}
		if b.scan(col, row, d) != nil {
			return col
		}
	}
	return -1
}

// dirs are the four axes a line can run along: east, north, north-east,
// north-west. Their opposites are covered by scanning both ways from the
// placed disc.
var dirs = [4][2]int{{1, 0}, {0, 1}, {1, 1}, {1, -1}}

// scan looks for a line of four through (col, row) for d.
//
// It never reads (col, row) itself, only the cells around it, so the same scan
// answers both questions this package asks: "did the disc I just placed win"
// and "would a disc placed here win". That is why [Board.WinningMove] needs no
// clone and writes nothing.
func (b *Board) scan(col, row int, d Disc) []int {
	for _, dir := range dirs {
		cells := []int{idx(col, row)}
		for _, sign := range [2]int{1, -1} {
			for step := 1; step < 4; step++ {
				c := col + dir[0]*sign*step
				r := row + dir[1]*sign*step
				if c < 0 || c >= Cols || r < 0 || r >= Rows {
					break
				}
				if b.cells[idx(c, r)] != d {
					break
				}
				cells = append(cells, idx(c, r))
			}
		}
		if len(cells) >= 4 {
			return trimLine(cells, dir, col, row)
		}
	}
	return nil
}

// trimLine reduces a run of five or six to the four cells adjacent to the disc
// that was just played, walking outward from it so the highlighted line always
// contains the winning move.
func trimLine(cells []int, dir [2]int, col, row int) []int {
	out := []int{idx(col, row)}
	for _, sign := range [2]int{1, -1} {
		for step := 1; step < 4 && len(out) < 4; step++ {
			c := col + dir[0]*sign*step
			r := row + dir[1]*sign*step
			if !contains(cells, idx(c, r)) {
				break
			}
			out = append(out, idx(c, r))
		}
	}
	sortInts(out)
	return out
}

func contains(haystack []int, needle int) bool {
	for _, v := range haystack {
		if v == needle {
			return true
		}
	}
	return false
}

// sortInts is an insertion sort. gno has no sort.Slice, and the input is four
// elements, so reaching for anything larger would be theatre.
func sortInts(a []int) {
	for i := 1; i < len(a); i++ {
		v := a[i]
		j := i - 1
		for j >= 0 && a[j] > v {
			a[j+1] = a[j]
			j--
		}
		a[j+1] = v
	}
}
