package minesweeper

import (
	"encoding/hex"
	"net/url"
	"strings"
)

const (
	Width  = 8
	Height = 8
	// Mines  = 4 They are random, from 4 (easy) to 10 (difficult) !
)

type Cell struct {
	IsMine        bool
	IsRevealed    bool
	AdjacentMines int
}

type Board struct {
	cells [][]Cell // height, width
	// todo probably add fields width and height
}

func NewBoard() *Board {
	var cells [][]Cell = make([][]Cell, Height)
	for i := range cells {
		cells[i] = make([]Cell, Width)
	}
	return &Board{
		cells: cells,
	}
}

// An empty hexstate will create a board and place mines.
// Otherwise a board is recovered from the state if possible (panic otherwise).
// input is a hex string where each hex-decoded byte 8 bits is 0b00ZYXXXX
//
//	XXXX: count of adjacent mines (4bits, valid ∈ 0-8),
//	Y: discovered bit
//	Z: isMine bit
func BoardFromRepr(hexstate string) *Board {
	state := stateToBytes(hexstate)
	board := NewBoard()
	if len(state) == 0 {
		board.placeMines()
	} else if len(state) != Width*Height {
		panic("invalid state length")
	} else {
		for i, o := range state {
			board.cells[i/Width][i%Width] = Cell{
				IsMine:        ((o & 0b_0010_0000) >> 5) == 1,
				IsRevealed:    ((o & 0b_0001_0000) >> 4) == 1,
				AdjacentMines: int(o & 0b_0000_1111),
			}
		}
	}
	return board
}

// ToHexRepr is the opposite operation of BoardFromRepr
// it outputs an hexadecimal string
func (b Board) ToHexRepr() string {
	var builder strings.Builder
	for i := 0; i < Width*Height; i++ {
		cell := b.cells[i/Width][i%Width]
		var isMine uint8 = 0
		var isRevealed uint8 = 0
		if cell.IsMine {
			isMine = 1
		}
		if cell.IsRevealed {
			isRevealed = 1
		}
		builder.WriteByte(
			0b_0000_0000 | (isMine << 5) | (isRevealed << 4) | (uint8(cell.AdjacentMines)),
		)
	}
	return hex.EncodeToString([]byte(builder.String()))
}

// show the board as a string,
// respective of the revealed status of the squares unless `force` is true.
func (b *Board) show(force bool) string {
	var buf strings.Builder
	for y := range b.cells {
		for x := range b.cells[y] {
			cell := b.cells[y][x]
			if cell.IsRevealed || force {
				if cell.IsMine {
					buf.WriteRune('+')
				} else if cell.AdjacentMines == 0 {
					buf.WriteRune('.')
				} else {
					buf.WriteRune('0' + int32(cell.AdjacentMines))
				}
			} else {
				buf.WriteRune('?')
			}
		}
		buf.WriteRune('\n')
	}
	return buf.String()
}

// Reveal a square, using some kind of floodfill, and return
// whether we are still alive after that...
func (b *Board) Reveal(x, y int) bool {
	if x < 0 || x >= Width || y < 0 || y >= Height {
		panic("Invalid input. Enter valid coordinates.")
	}
	if b.cells[y][x].IsRevealed || b.cells[y][x].IsMine {
		return !b.cells[y][x].IsMine
	}
	b.cells[y][x].IsRevealed = true
	if b.cells[y][x].AdjacentMines == 0 {
		for i := -1; i <= 1; i++ {
			for j := -1; j <= 1; j++ {
				if i == 0 && j == 0 {
					continue
				}
				adjX, adjY := x+j, y+i
				if adjX >= 0 && adjX < Width && adjY >= 0 && adjY < Height {
					b.Reveal(adjX, adjY)
				}
			}
		}
	}
	return true
}

func (b *Board) placeMines() {
	// Mines vary between 4 (easy) to 10 (relatively difficult)
	mines := 4 + Intn(10-4)
	for i := 0; i < mines; i++ {
		x, y := Intn(Width), Intn(Height)
		if b.cells[y][x].IsMine {
			i-- // Retry if mine is already placed
			continue
		}
		b.cells[y][x].IsMine = true
		b.updateAdjacentMines(x, y)
	}
}

func (b *Board) updateAdjacentMines(x, y int) {
	for i := -1; i <= 1; i++ {
		for j := -1; j <= 1; j++ {
			if i == 0 && j == 0 {
				continue
			}
			adjX, adjY := x+j, y+i
			if adjX >= 0 && adjX < Width && adjY >= 0 && adjY < Height {
				b.cells[adjY][adjX].AdjacentMines++
			}
		}
	}
}

func stateToBytes(urlEncodedHex string) []byte {
	decoded, err := url.QueryUnescape(urlEncodedHex)
	if err != nil {
		panic("Error decoding URL:" + err.Error())
	}
	bytes, err := hex.DecodeString(decoded)
	if err != nil {
		panic("Error decoding hex:" + err.Error())
	}
	return bytes
}
