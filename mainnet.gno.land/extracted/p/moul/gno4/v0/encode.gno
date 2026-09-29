package gno4

import "strings"

// Encode returns the whole game as one string: the 1-based column of each
// move, in order. An empty game is the empty string, a full game is 42 bytes.
//
// The position is not stored, because it is not information: replaying the
// moves reproduces it exactly, including the winner and the winning line. That
// is what lets a match be a URL, a chain event and a test fixture without three
// encoders that can disagree.
func (b *Board) Encode() string {
	var sb strings.Builder
	for _, col := range b.moves {
		sb.WriteByte(byte('1' + col))
	}
	return sb.String()
}

// Decode replays an encoding produced by [Board.Encode].
//
// It replays through [Board.Drop] rather than writing cells directly, so an
// encoding that describes an impossible game (a column overflowing, a move
// after the win) is rejected here instead of becoming a board no rule allows.
// Nothing else in this package can construct an illegal position.
func Decode(s string) (*Board, error) {
	b := New()
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '1' || c > '7' {
			return nil, ErrBadEncoding
		}
		if _, err := b.Drop(int(c - '1')); err != nil {
			return nil, ErrBadEncoding
		}
	}
	return b, nil
}

// String renders the board as seven columns of ASCII, top row first, the way a
// player looks at it. Empty is '.', Red is 'R', Yellow is 'Y'.
//
// This is the debugging view and the one tests assert against. What gnoweb
// shows is [Board.Image]; what a terminal or a diff shows is this.
func (b *Board) String() string {
	var sb strings.Builder
	for row := Rows - 1; row >= 0; row-- {
		for col := 0; col < Cols; col++ {
			switch b.At(col, row) {
			case Red:
				sb.WriteByte('R')
			case Yellow:
				sb.WriteByte('Y')
			default:
				sb.WriteByte('.')
			}
		}
		sb.WriteByte('\n')
	}
	sb.WriteString("1234567\n")
	return sb.String()
}
