// Package tessespike is a throwaway Phase 1 spike used to time Onyx gpao approval.
package tessespike

import "gno.land/p/nt/ufmt/v0"

type Board struct {
	Grid  [25]uint8
	Turn  uint8
	Moves int
}

func NewBoard() *Board {
	b := &Board{Turn: 1}
	b.Grid[10] = 1
	b.Grid[14] = 2
	return b
}

func (b *Board) Bump() { b.Moves++ }

func (b *Board) String() string {
	return ufmt.Sprintf("turn=%d moves=%d", b.Turn, b.Moves)
}
