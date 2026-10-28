package minichess

func lastRank(c Color) int {
	if c == White {
		return Size - 1
	}
	return 0
}

// Attacked reports whether square sq is attacked by any piece of colour by.
func (p Position) Attacked(sq int, by Color) bool {
	return newEngine(&p).attacked(sq, by)
}

// InCheck reports whether the side to move is in check.
func (p Position) InCheck() bool {
	return newEngine(&p).inCheck()
}

// LegalMoves returns all legal moves for the side to move.
func (p Position) LegalMoves() []Move {
	enc := newEngine(&p).legal()
	out := make([]Move, len(enc))
	for i, m := range enc {
		out[i] = decode(m)
	}
	return out
}

// Play applies a move without validating it and returns the new position.
// Callers must only pass moves obtained from LegalMoves or FindLegal.
func (p Position) Play(m Move) Position {
	e := newEngine(&p)
	e.make(m.encode())
	full := p.Fullmove
	if p.Turn == Black {
		full++
	}
	return e.position(full)
}

// IsIrreversible reports whether m is a capture or pawn move (resets the
// repetition history and the 50-move counter).
func (p Position) IsIrreversible(m Move) bool {
	return p.Board[m.From].Type() == Pawn || p.Board[m.To] != Empty
}

// FindLegal matches m against the legal moves. A promotion move given
// without a piece defaults to a queen. Returns false if m is illegal.
func (p Position) FindLegal(m Move) (Move, bool) {
	if m.Promo == Empty {
		pc := p.Board[m.From]
		if pc.Type() == Pawn && pc.Color() == p.Turn && m.To/Size == lastRank(p.Turn) {
			m.Promo = Queen
		}
	}
	want := m.encode()
	for _, lm := range newEngine(&p).legal() {
		if lm == want {
			return m, true
		}
	}
	return m, false
}

// Status describes whether the game is still going and how it ended.
type Status int

const (
	Ongoing Status = iota
	Checkmate
	Stalemate
	FiftyMoveDraw
	InsufficientMaterial
)

func (s Status) String() string {
	switch s {
	case Ongoing:
		return "ongoing"
	case Checkmate:
		return "checkmate"
	case Stalemate:
		return "stalemate"
	case FiftyMoveDraw:
		return "50-move rule"
	case InsufficientMaterial:
		return "insufficient material"
	}
	return "unknown"
}

// Status computes the game status from the position alone. Threefold
// repetition needs move history and is handled by the caller.
func (p Position) Status() Status {
	e := newEngine(&p)
	if len(e.legal()) == 0 {
		if e.inCheck() {
			return Checkmate
		}
		return Stalemate
	}
	if p.insufficientMaterial() {
		return InsufficientMaterial
	}
	if p.Halfmove >= 100 {
		return FiftyMoveDraw
	}
	return Ongoing
}

// insufficientMaterial: only kings, or kings plus a single minor piece.
func (p Position) insufficientMaterial() bool {
	minors := 0
	for _, pc := range p.Board {
		switch pc.Type() {
		case Pawn, Rook, Queen:
			return false
		case Knight, Bishop:
			minors++
		}
	}
	return minors <= 1
}
