package minesweeper

import (
	"testing"

	"gno.land/p/demo/urequire"
)

func TestBoard(t *testing.T) {
	{
		board := NewBoard()
		urequire.False(t, board == nil)
		urequire.Equal(t, len(board.cells), Height)
		for i := 0; i < Height; i++ {
			urequire.Equal(t, len(board.cells[i]), Width)
		}
	}
	{
		var board *Board
		urequire.NotPanics(t, func() {
			board = BoardFromRepr("")
		})
		// check all squares unrevealed
		// check some mines were placed
		foundMines := false
		for i := 0; i < Width*Height; i++ {
			urequire.False(t, board.cells[i/Width][i%Width].IsRevealed)
			if board.cells[i/Width][i%Width].IsMine {
				foundMines = true
			}
		}
		urequire.True(t, foundMines)

		// check BoardFromRepr(hex).ToHexRepr() == hex
		hex := board.ToHexRepr()
		urequire.Equal(t, len(hex), 2*Width*Height, "len(hex), 2*Width*Height")
		urequire.Equal(t, hex, BoardFromRepr(hex).ToHexRepr(), "hex, BoardFromRepr(hex).ToHexRepr()")
	}
	{
		urequire.PanicsWithMessage(t, "invalid state length", func() {
			BoardFromRepr("0FaaBBccDDee")
		})
		urequire.PanicsWithMessage(t, "Error decoding hex:encoding/hex: invalid byte: 120", func() {
			BoardFromRepr("xx")
		})
	}
}
