// Package minichess implements standard chess (8x8) for gno.land realms:
// position representation, FEN, full move legality (castling, en passant,
// promotion), game-end detection and a gas-bounded bot.
//
// The package is pure and stateless: Position is a value type, and every
// method returns a new Position instead of mutating the receiver.
package minichess

import (
	"errors"
	"strconv"
	"strings"
)

const (
	Size       = 8
	NumSquares = Size * Size
)

// Piece is a signed piece code: positive for white, negative for black.
type Piece int8

const (
	Empty  Piece = 0
	Pawn   Piece = 1
	Knight Piece = 2
	Bishop Piece = 3
	Rook   Piece = 4
	Queen  Piece = 5
	King   Piece = 6
)

// Color is the side to move.
type Color int8

const (
	White Color = 0
	Black Color = 1
)

func (c Color) Other() Color { return 1 - c }

func (c Color) String() string {
	if c == White {
		return "white"
	}
	return "black"
}

// Type returns the unsigned piece type.
func (p Piece) Type() Piece {
	if p < 0 {
		return -p
	}
	return p
}

// Color returns the colour of a non-empty piece.
func (p Piece) Color() Color {
	if p < 0 {
		return Black
	}
	return White
}

func colored(t Piece, c Color) Piece {
	if c == Black {
		return -t
	}
	return t
}

// Castling rights bits.
const (
	CastleWK = 1 // white king side (e1g1)
	CastleWQ = 2 // white queen side (e1c1)
	CastleBK = 4 // black king side (e8g8)
	CastleBQ = 8 // black queen side (e8c8)
)

// Position is a complete game state.
type Position struct {
	Board    [NumSquares]Piece // index = rank*8 + file; a1 = 0, h8 = 63
	Turn     Color
	Castling int // CastleWK|CastleWQ|CastleBK|CastleBQ bits
	EP       int // en passant target square, or -1
	Halfmove int // plies since the last capture or pawn move
	Fullmove int // starts at 1, incremented after black moves
}

// Move is a move from one square to another, with an optional promotion
// piece type (Knight, Bishop, Rook or Queen). Castling is the king's move
// (e1g1); en passant is the capturing pawn's move to the target square.
type Move struct {
	From, To int
	Promo    Piece
}

// StartFEN is the standard starting position.
const StartFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

// NewGame returns the starting position.
func NewGame() Position {
	p, err := ParseFEN(StartFEN)
	if err != nil {
		panic(err)
	}
	return p
}

var pieceChars = " pnbrqk"

func pieceToChar(p Piece) string {
	if p == Empty {
		return "."
	}
	ch := string(pieceChars[p.Type()])
	if p.Color() == White {
		return strings.ToUpper(ch)
	}
	return ch
}

func charToPiece(ch byte) (Piece, bool) {
	lower := ch
	white := false
	if ch >= 'A' && ch <= 'Z' {
		lower = ch - 'A' + 'a'
		white = true
	}
	idx := strings.IndexByte(pieceChars, lower)
	if idx <= 0 {
		return Empty, false
	}
	if white {
		return Piece(idx), true
	}
	return -Piece(idx), true
}

// ParseFEN parses standard FEN. The halfmove and fullmove fields are
// optional.
func ParseFEN(s string) (Position, error) {
	var p Position
	p.EP = -1
	fields := strings.Fields(s)
	if len(fields) < 2 {
		return p, errors.New("chess: FEN needs board and side to move")
	}
	ranks := strings.Split(fields[0], "/")
	if len(ranks) != Size {
		return p, errors.New("chess: FEN must have 8 ranks")
	}
	kings := [2]int{}
	for i, row := range ranks {
		r := Size - 1 - i
		f := 0
		for j := 0; j < len(row); j++ {
			ch := row[j]
			if ch >= '1' && ch <= '8' {
				f += int(ch - '0')
				continue
			}
			pc, ok := charToPiece(ch)
			if !ok {
				return p, errors.New("chess: bad FEN piece " + string(ch))
			}
			if f >= Size {
				return p, errors.New("chess: FEN rank too long")
			}
			if pc == King {
				kings[0]++
			} else if pc == -King {
				kings[1]++
			}
			p.Board[r*Size+f] = pc
			f++
		}
		if f != Size {
			return p, errors.New("chess: FEN rank has wrong length")
		}
	}
	if kings[0] != 1 || kings[1] != 1 {
		return p, errors.New("chess: FEN needs exactly one king per side")
	}
	switch fields[1] {
	case "w":
		p.Turn = White
	case "b":
		p.Turn = Black
	default:
		return p, errors.New("chess: FEN side must be w or b")
	}
	if len(fields) > 2 && fields[2] != "-" {
		for _, c := range fields[2] {
			switch c {
			case 'K':
				p.Castling |= CastleWK
			case 'Q':
				p.Castling |= CastleWQ
			case 'k':
				p.Castling |= CastleBK
			case 'q':
				p.Castling |= CastleBQ
			default:
				return p, errors.New("chess: bad FEN castling field")
			}
		}
	}
	if len(fields) > 3 && fields[3] != "-" {
		sq, ok := ParseSquare(fields[3])
		if !ok {
			return p, errors.New("chess: bad FEN en passant square")
		}
		p.EP = sq
	}
	p.Fullmove = 1
	if len(fields) > 4 {
		n, err := strconv.Atoi(fields[4])
		if err != nil || n < 0 {
			return p, errors.New("chess: bad halfmove clock")
		}
		p.Halfmove = n
	}
	if len(fields) > 5 {
		n, err := strconv.Atoi(fields[5])
		if err != nil || n < 1 {
			return p, errors.New("chess: bad fullmove number")
		}
		p.Fullmove = n
	}
	return p, nil
}

func (p Position) placement() string {
	var sb strings.Builder
	for r := Size - 1; r >= 0; r-- {
		empty := 0
		for f := 0; f < Size; f++ {
			pc := p.Board[r*Size+f]
			if pc == Empty {
				empty++
				continue
			}
			if empty > 0 {
				sb.WriteString(strconv.Itoa(empty))
				empty = 0
			}
			sb.WriteString(pieceToChar(pc))
		}
		if empty > 0 {
			sb.WriteString(strconv.Itoa(empty))
		}
		if r > 0 {
			sb.WriteString("/")
		}
	}
	return sb.String()
}

func (p Position) castlingString() string {
	s := ""
	if p.Castling&CastleWK != 0 {
		s += "K"
	}
	if p.Castling&CastleWQ != 0 {
		s += "Q"
	}
	if p.Castling&CastleBK != 0 {
		s += "k"
	}
	if p.Castling&CastleBQ != 0 {
		s += "q"
	}
	if s == "" {
		return "-"
	}
	return s
}

func (p Position) side() string {
	if p.Turn == White {
		return "w"
	}
	return "b"
}

// FEN returns the full FEN string of the position.
func (p Position) FEN() string {
	ep := "-"
	if p.EP >= 0 {
		ep = SquareName(p.EP)
	}
	return p.placement() + " " + p.side() + " " + p.castlingString() + " " + ep +
		" " + strconv.Itoa(p.Halfmove) + " " + strconv.Itoa(p.Fullmove)
}

// BoardKey identifies the position for threefold repetition: placement,
// side to move, castling rights and an en passant square only when an en
// passant capture is actually available.
func (p Position) BoardKey() string {
	ep := "-"
	if p.EP >= 0 && p.epCapturePossible() {
		ep = SquareName(p.EP)
	}
	return p.placement() + " " + p.side() + " " + p.castlingString() + " " + ep
}

func (p Position) epCapturePossible() bool {
	e := newEngine(&p)
	for _, m := range e.legal() {
		if (m>>6)&63 == p.EP && e.b[m&63].Type() == Pawn {
			return true
		}
	}
	return false
}

// PieceAt returns the piece on a square given by name, e.g. "e4".
func (p Position) PieceAt(square string) Piece {
	sq, ok := ParseSquare(square)
	if !ok {
		return Empty
	}
	return p.Board[sq]
}

// SquareName converts an index to algebraic notation ("a1".."h8").
func SquareName(sq int) string {
	return string(rune('a'+sq%Size)) + string(rune('1'+sq/Size))
}

// ParseSquare converts algebraic notation to an index.
func ParseSquare(s string) (int, bool) {
	if len(s) != 2 {
		return 0, false
	}
	f := int(s[0]) - 'a'
	r := int(s[1]) - '1'
	if f < 0 || f >= Size || r < 0 || r >= Size {
		return 0, false
	}
	return r*Size + f, true
}

// String returns the move in coordinate notation, e.g. "e2e4" or "e7e8q".
func (m Move) String() string {
	s := SquareName(m.From) + SquareName(m.To)
	if m.Promo != Empty {
		s += string(pieceChars[m.Promo.Type()])
	}
	return s
}

// ParseMove parses coordinate notation: "e2e4", "e1g1" or "e7e8n".
// It does not check legality; use Position.FindLegal for that.
func ParseMove(s string) (Move, error) {
	s = strings.ToLower(strings.TrimSpace(s))
	var m Move
	if len(s) != 4 && len(s) != 5 {
		return m, errors.New("chess: move must look like e2e4 or e7e8q")
	}
	from, ok1 := ParseSquare(s[0:2])
	to, ok2 := ParseSquare(s[2:4])
	if !ok1 || !ok2 {
		return m, errors.New("chess: bad square in move " + s)
	}
	m.From, m.To = from, to
	if len(s) == 5 {
		switch s[4] {
		case 'n':
			m.Promo = Knight
		case 'b':
			m.Promo = Bishop
		case 'r':
			m.Promo = Rook
		case 'q':
			m.Promo = Queen
		default:
			return m, errors.New("chess: promotion must be q, r, b or n")
		}
	}
	return m, nil
}
