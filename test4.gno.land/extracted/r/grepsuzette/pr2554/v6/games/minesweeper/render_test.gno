package minesweeper

import (
	"testing"

	"gno.land/p/demo/urequire"
)

func TestParseEmptyPath(t *testing.T) {
	{
		board, x, y, debug := parsePath("")
		urequire.True(t, board != nil, "board was created")
	}
	{
		board, x, y, debug := parsePath("state=21210220010000000303020202010000200100012001000001010001010100000000010101000000000102210201010000012103032102010001010221020220")
		urequire.True(t, board != nil, "board was recovered")
	}
}

func TestPlay(t *testing.T) {
	newgame := func() *Board {
		return BoardFromRepr("21210220010000000303020202010000200100012001000001010001010100000000010101000000000102210201010000012103032102010001010221020220")
	}

	// ++2+1...  we always play the same game from the start in this test
	// 332221..  the mines are indicated by +
	// +1.1+1..
	// 11.111..
	// ..111...
	// .12+211.
	// .1+33+21
	// .112+22+
	urequire.False(t, newgame().Reveal(0, 0), "we exploded in the topleft corner")
	urequire.False(t, newgame().Reveal(1, 0), "we exploded in (1,0)")
	urequire.True(t, newgame().Reveal(2, 0), "we survived uncovering (2,0)")
	urequire.False(t, newgame().Reveal(3, 0), "we exploded in (3,0)")
	urequire.True(t, newgame().Reveal(4, 0), "we survived uncovering (4,0)")
	urequire.False(t, newgame().Reveal(7, 7), "we exploded in the bottomright corner")

	// let's now play a sequence and test revealing
	board := newgame()
	urequire.True(t, board.Reveal(7, 0), "we survived the topright corner")
	numRevealed := 0
	for i := 0; i < Width*Height; i++ {
		if board.cells[i/Width][i%Width].IsRevealed {
			numRevealed++
		}
	}
	urequire.Equal(t, numRevealed, 25, "clicking topright corner reveals 25 squares")
}
