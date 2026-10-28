package minichess

// engine is the mutable, allocation-light core used by move generation and
// the bot. GnoVM charges gas per operation (roughly 1k gas per loop
// iteration, ~4k per append), so the engine uses precomputed tables, piece
// lists (only occupied squares are visited), integer-encoded moves written
// into reused buffers, in-place make/unmake and an incrementally updated
// evaluation.

// Encoded move: from | to<<6 | promo<<12.
func enc(from, to int, promo Piece) int { return from | to<<6 | int(promo)<<12 }

func decode(m int) Move {
	return Move{From: m & 63, To: (m >> 6) & 63, Promo: Piece(m >> 12)}
}

func (m Move) encode() int { return enc(m.From, m.To, m.Promo) }

const bufSize = 256 // more than the maximum number of pseudo-legal moves

// Lookup tables. A deployed package pays a storage deposit for everything
// it persists, so target-square lists are stored as strings (one byte per
// square): compact on-chain, and ranging over them costs about the same
// gas as ranging over a slice.
var (
	knightT [NumSquares]string
	kingT   [NumSquares]string
	rays    [NumSquares * 8]string // [sq*8+dir]; dirs 0-3 orthogonal, 4-7 diagonal
	pawnAtk [2 * NumSquares]string // [c*64+sq]: squares a pawn of colour c on sq attacks
	psqt    [13][NumSquares]int    // [piece+6][sq], signed (white +)

	// geo[a*64+b] flags: geoLine (shared rank/file/diagonal), geoKnight,
	// geoKing (adjacent).
	geo string
)

const (
	geoLine   byte = 1
	geoKnight byte = 2
	geoKing   byte = 4
)

var pieceValue = [7]int{0, 100, 320, 330, 500, 900, 0}

func inside(r, f int) bool { return r >= 0 && r < Size && f >= 0 && f < Size }

// init fills the lookup tables. Pure packages are immutable after init, so
// the tables are built once here and only read afterwards.
func init() {
	dirs8 := [8][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {1, -1}, {-1, 1}, {-1, -1}}
	knightD := [8][2]int{{1, 2}, {2, 1}, {2, -1}, {1, -2}, {-1, -2}, {-2, -1}, {-2, 1}, {-1, 2}}

	// Piece-square tables ("simplified evaluation function"), written
	// from white's point of view with rank 8 first.
	pst := [7][64]int{
		{},
		{ // pawn
			0, 0, 0, 0, 0, 0, 0, 0,
			50, 50, 50, 50, 50, 50, 50, 50,
			10, 10, 20, 30, 30, 20, 10, 10,
			5, 5, 10, 25, 25, 10, 5, 5,
			0, 0, 0, 20, 20, 0, 0, 0,
			5, -5, -10, 0, 0, -10, -5, 5,
			5, 10, 10, -20, -20, 10, 10, 5,
			0, 0, 0, 0, 0, 0, 0, 0,
		},
		{ // knight
			-50, -40, -30, -30, -30, -30, -40, -50,
			-40, -20, 0, 0, 0, 0, -20, -40,
			-30, 0, 10, 15, 15, 10, 0, -30,
			-30, 5, 15, 20, 20, 15, 5, -30,
			-30, 0, 15, 20, 20, 15, 0, -30,
			-30, 5, 10, 15, 15, 10, 5, -30,
			-40, -20, 0, 5, 5, 0, -20, -40,
			-50, -40, -30, -30, -30, -30, -40, -50,
		},
		{ // bishop
			-20, -10, -10, -10, -10, -10, -10, -20,
			-10, 0, 0, 0, 0, 0, 0, -10,
			-10, 0, 5, 10, 10, 5, 0, -10,
			-10, 5, 5, 10, 10, 5, 5, -10,
			-10, 0, 10, 10, 10, 10, 0, -10,
			-10, 10, 10, 10, 10, 10, 10, -10,
			-10, 5, 0, 0, 0, 0, 5, -10,
			-20, -10, -10, -10, -10, -10, -10, -20,
		},
		{ // rook
			0, 0, 0, 0, 0, 0, 0, 0,
			5, 10, 10, 10, 10, 10, 10, 5,
			-5, 0, 0, 0, 0, 0, 0, -5,
			-5, 0, 0, 0, 0, 0, 0, -5,
			-5, 0, 0, 0, 0, 0, 0, -5,
			-5, 0, 0, 0, 0, 0, 0, -5,
			-5, 0, 0, 0, 0, 0, 0, -5,
			0, 0, 0, 5, 5, 0, 0, 0,
		},
		{ // queen
			-20, -10, -10, -5, -5, -10, -10, -20,
			-10, 0, 0, 0, 0, 0, 0, -10,
			-10, 0, 5, 5, 5, 5, 0, -10,
			-5, 0, 5, 5, 5, 5, 0, -5,
			0, 0, 5, 5, 5, 5, 0, -5,
			-10, 5, 5, 5, 5, 5, 0, -10,
			-10, 0, 5, 0, 0, 0, 0, -10,
			-20, -10, -10, -5, -5, -10, -10, -20,
		},
		{ // king (middlegame)
			-30, -40, -40, -50, -50, -40, -40, -30,
			-30, -40, -40, -50, -50, -40, -40, -30,
			-30, -40, -40, -50, -50, -40, -40, -30,
			-30, -40, -40, -50, -50, -40, -40, -30,
			-20, -30, -30, -40, -40, -30, -30, -20,
			-10, -20, -20, -20, -20, -20, -20, -10,
			20, 20, 0, 0, 0, 0, 20, 20,
			20, 30, 10, 0, 0, 10, 30, 20,
		},
	}

	sqs := func(list []int) string {
		b := make([]byte, len(list))
		for i, v := range list {
			b[i] = byte(v)
		}
		return string(b)
	}
	for sq := 0; sq < NumSquares; sq++ {
		r, f := sq/Size, sq%Size
		var kn, kg []int
		for _, d := range knightD {
			if inside(r+d[0], f+d[1]) {
				kn = append(kn, (r+d[0])*Size+f+d[1])
			}
		}
		for i, d := range dirs8 {
			if inside(r+d[0], f+d[1]) {
				kg = append(kg, (r+d[0])*Size+f+d[1])
			}
			var ray []int
			nr, nf := r+d[0], f+d[1]
			for inside(nr, nf) {
				ray = append(ray, nr*Size+nf)
				nr += d[0]
				nf += d[1]
			}
			rays[sq*8+i] = sqs(ray)
		}
		knightT[sq] = sqs(kn)
		kingT[sq] = sqs(kg)
		for c := 0; c < 2; c++ {
			nr := r + 1
			if c == 1 {
				nr = r - 1
			}
			var pa []int
			for _, df := range [2]int{-1, 1} {
				if inside(nr, f+df) {
					pa = append(pa, nr*Size+f+df)
				}
			}
			pawnAtk[c*NumSquares+sq] = sqs(pa)
		}
		for t := 1; t <= 6; t++ {
			v := pieceValue[t] + pst[t][(Size-1-r)*Size+f]
			psqt[6+t][sq] = v
			psqt[6-t][(Size-1-r)*Size+f] = -v
		}
	}

	g8 := make([]byte, NumSquares*NumSquares)
	for a := 0; a < NumSquares; a++ {
		for b := 0; b < NumSquares; b++ {
			if a == b {
				continue
			}
			dr, df := a/Size-b/Size, a%Size-b%Size
			var g byte
			if dr == 0 || df == 0 || dr == df || dr == -df {
				g |= geoLine
			}
			if dr*df == 2 || dr*df == -2 {
				g |= geoKnight
			}
			if dr >= -1 && dr <= 1 && df >= -1 && df <= 1 {
				g |= geoKing
			}
			g8[a*NumSquares+b] = g
		}
	}
	geo = string(g8)
}

// castleKeep returns the castling rights that survive a move touching sq.
func castleKeep(sq int) int {
	switch sq {
	case 0:
		return ^CastleWQ
	case 4:
		return ^(CastleWK | CastleWQ)
	case 7:
		return ^CastleWK
	case 56:
		return ^CastleBQ
	case 60:
		return ^(CastleBK | CastleBQ)
	case 63:
		return ^CastleBK
	}
	return ^0
}

type undo struct {
	moved    Piece
	captured Piece
	capSq    int
	capIdx   int
	castle   int
	ep       int
	half     int
	score    int
	special  int // 0 normal, 1 en passant, 2 castling
}

// plyBuf holds the moves generated at one search ply.
type plyBuf struct {
	caps   []int
	quiets []int
	nc, nq int
}

func newPlyBuf() *plyBuf {
	return &plyBuf{caps: make([]int, bufSize), quiets: make([]int, bufSize)}
}

type engine struct {
	b      [NumSquares]Piece
	turn   Color
	castle int
	ep     int
	half   int
	kings  [2]int
	score  int // white-perspective evaluation, updated incrementally

	// Piece lists: squares of each side's pieces, and each occupied
	// square's index in its list.
	plist  [2][16]int
	pcount [2]int
	pidx   [NumSquares]int

	nodes   int
	budget  int
	qdepth  int
	aborted bool
	bufs    []*plyBuf
	killers [maxPly + 2][2]int // quiet moves that caused a cutoff, per ply
}

func newEngine(p *Position) *engine {
	e := &engine{b: p.Board, turn: p.Turn, castle: p.Castling, ep: p.EP, half: p.Halfmove}
	for sq := 0; sq < NumSquares; sq++ {
		pc := e.b[sq]
		if pc == Empty {
			continue
		}
		e.score += psqt[pc+6][sq]
		c := 0
		if pc < 0 {
			c = 1
		}
		if pc.Type() == King {
			e.kings[c] = sq
		}
		if e.pcount[c] < 16 {
			e.pidx[sq] = e.pcount[c]
			e.plist[c][e.pcount[c]] = sq
			e.pcount[c]++
		}
	}
	return e
}

func (e *engine) buf(ply int) *plyBuf {
	for len(e.bufs) <= ply {
		e.bufs = append(e.bufs, newPlyBuf())
	}
	return e.bufs[ply]
}

// attacked reports whether sq is attacked by colour by.
func (e *engine) attacked(sq int, by Color) bool {
	sign := Piece(1)
	if by == Black {
		sign = -1
	}
	b := &e.b
	// A pawn of colour `by` attacks sq if it sits on a square that a pawn
	// of the other colour on sq would attack.
	pw := sign * Pawn
	for _, ch := range pawnAtk[int(1-by)*NumSquares+sq] {
		if b[int(ch)] == pw {
			return true
		}
	}
	kn := sign * Knight
	for _, ch := range knightT[sq] {
		if b[int(ch)] == kn {
			return true
		}
	}
	kg := sign * King
	for _, ch := range kingT[sq] {
		if b[int(ch)] == kg {
			return true
		}
	}
	q := sign * Queen
	slider := sign * Rook
	for d := 0; d < 8; d++ {
		if d == 4 {
			slider = sign * Bishop
		}
		for _, ch := range rays[sq*8+d] {
			pc := b[int(ch)]
			if pc != Empty {
				if pc == slider || pc == q {
					return true
				}
				break
			}
		}
	}
	return false
}

func (e *engine) inCheck() bool {
	return e.attacked(e.kings[e.turn], 1-e.turn)
}

// gen fills pb with pseudo-legal moves: captures and queen promotions in
// pb.caps, everything else in pb.quiets (skipped when capsOnly).
func (e *engine) gen(pb *plyBuf, capsOnly bool) {
	caps, quiets := pb.caps, pb.quiets
	nc, nq := 0, 0
	b := &e.b
	us := e.turn
	sign := Piece(1)
	fwd, startRank, promoRank := Size, 1, Size-1
	if us == Black {
		sign, fwd, startRank, promoRank = -1, -Size, Size-2, 0
	}
	list := &e.plist[us]
	for i := 0; i < e.pcount[us]; i++ {
		sq := list[i]
		pc := b[sq] * sign
		switch pc {
		case Pawn:
			to := sq + fwd
			promo := to/Size == promoRank
			if b[to] == Empty {
				if promo {
					caps[nc] = enc(sq, to, Queen)
					nc++
					if !capsOnly {
						quiets[nq] = enc(sq, to, Knight)
						quiets[nq+1] = enc(sq, to, Rook)
						quiets[nq+2] = enc(sq, to, Bishop)
						nq += 3
					}
				} else if !capsOnly {
					quiets[nq] = sq | to<<6
					nq++
					if sq/Size == startRank && b[to+fwd] == Empty {
						quiets[nq] = sq | (to+fwd)<<6
						nq++
					}
				}
			}
			for _, ch := range pawnAtk[int(us)*NumSquares+sq] {
				t := int(ch)
				if b[t]*sign < 0 {
					if promo {
						caps[nc] = enc(sq, t, Queen)
						nc++
						if !capsOnly {
							quiets[nq] = enc(sq, t, Knight)
							quiets[nq+1] = enc(sq, t, Rook)
							quiets[nq+2] = enc(sq, t, Bishop)
							nq += 3
						}
					} else {
						caps[nc] = sq | t<<6
						nc++
					}
				} else if t == e.ep {
					caps[nc] = sq | t<<6
					nc++
				}
			}
		case Knight, King:
			targets := knightT[sq]
			if pc == King {
				targets = kingT[sq]
			}
			for _, ch := range targets {
				t := int(ch)
				v := b[t]
				if v == Empty {
					if !capsOnly {
						quiets[nq] = sq | t<<6
						nq++
					}
				} else if v*sign < 0 {
					caps[nc] = sq | t<<6
					nc++
				}
			}
		default: // sliders
			lo, hi := 0, 8
			if pc == Rook {
				hi = 4
			} else if pc == Bishop {
				lo = 4
			}
			for d := lo; d < hi; d++ {
				for _, ch := range rays[sq*8+d] {
					t := int(ch)
					v := b[t]
					if v == Empty {
						if !capsOnly {
							quiets[nq] = sq | t<<6
							nq++
						}
						continue
					}
					if v*sign < 0 {
						caps[nc] = sq | t<<6
						nc++
					}
					break
				}
			}
		}
	}
	if !capsOnly && e.castle != 0 {
		nq = e.genCastles(quiets, nq)
	}
	pb.nc, pb.nq = nc, nq
}

// genCastles adds castling moves. The king may not castle out of, through
// or into check, and the squares between king and rook must be empty.
func (e *engine) genCastles(quiets []int, nq int) int {
	b := &e.b
	them := 1 - e.turn
	base, rook, kRight, qRight := 0, Rook, CastleWK, CastleWQ
	if e.turn == Black {
		base, rook, kRight, qRight = 56, -Rook, CastleBK, CastleBQ
	}
	k := base + 4
	if e.castle&kRight != 0 && b[base+5] == Empty && b[base+6] == Empty && b[base+7] == rook &&
		!e.attacked(k, them) && !e.attacked(k+1, them) && !e.attacked(k+2, them) {
		quiets[nq] = k | (k+2)<<6
		nq++
	}
	if e.castle&qRight != 0 && b[base+3] == Empty && b[base+2] == Empty && b[base+1] == Empty &&
		b[base] == rook && !e.attacked(k, them) && !e.attacked(k-1, them) && !e.attacked(k-2, them) {
		quiets[nq] = k | (k-2)<<6
		nq++
	}
	return nq
}

// movePiece updates the board and piece list for a piece moving from->to.
func (e *engine) movePiece(c Color, from, to int) {
	i := e.pidx[from]
	e.plist[c][i] = to
	e.pidx[to] = i
	e.b[to] = e.b[from]
	e.b[from] = Empty
}

// removePiece takes the piece on sq out of colour c's list; returns its
// former index so restorePiece can undo it exactly.
func (e *engine) removePiece(c Color, sq int) int {
	i := e.pidx[sq]
	n := e.pcount[c] - 1
	last := e.plist[c][n]
	e.plist[c][i] = last
	e.pidx[last] = i
	e.pcount[c] = n
	return i
}

func (e *engine) restorePiece(c Color, sq, i int) {
	n := e.pcount[c]
	moved := e.plist[c][i]
	e.plist[c][n] = moved
	e.pidx[moved] = n
	e.plist[c][i] = sq
	e.pidx[sq] = i
	e.pcount[c] = n + 1
}

func (e *engine) make(m int) undo {
	from, to := m&63, (m>>6)&63
	us, them := e.turn, 1-e.turn
	pc := e.b[from]
	pt := pc.Type()
	u := undo{moved: pc, capSq: to, castle: e.castle, ep: e.ep, half: e.half, score: e.score}

	capt := e.b[to]
	if pt == Pawn && to == e.ep && capt == Empty && (from&7) != (to&7) {
		// En passant: the captured pawn is behind the target square.
		u.special = 1
		if us == White {
			u.capSq = to - Size
		} else {
			u.capSq = to + Size
		}
		capt = e.b[u.capSq]
	}
	u.captured = capt
	if capt != Empty {
		u.capIdx = e.removePiece(them, u.capSq)
		e.score -= psqt[capt+6][u.capSq]
		e.b[u.capSq] = Empty
	}

	e.movePiece(us, from, to)
	np := pc
	if m >= 4096 {
		np = Piece(m >> 12)
		if pc < 0 {
			np = -np
		}
		e.b[to] = np
	}
	e.score += psqt[np+6][to] - psqt[pc+6][from]

	if pt == King {
		e.kings[us] = to
		if to-from == 2 || from-to == 2 {
			u.special = 2
			rf, rt := from+3, from+1
			if to < from {
				rf, rt = from-4, from-1
			}
			rk := e.b[rf]
			e.movePiece(us, rf, rt)
			e.score += psqt[rk+6][rt] - psqt[rk+6][rf]
		}
	}
	if e.castle != 0 {
		e.castle &= castleKeep(from) & castleKeep(to)
	}
	e.ep = -1
	if pt == Pawn && (to-from == 16 || from-to == 16) {
		e.ep = (from + to) / 2
	}
	if pt == Pawn || capt != Empty {
		e.half = 0
	} else {
		e.half++
	}
	e.turn = them
	return u
}

func (e *engine) unmake(m int, u undo) {
	from, to := m&63, (m>>6)&63
	them := e.turn
	us := 1 - them
	e.turn = us
	if u.special == 2 {
		rf, rt := from+3, from+1
		if to < from {
			rf, rt = from-4, from-1
		}
		e.movePiece(us, rt, rf)
	}
	e.movePiece(us, to, from)
	e.b[from] = u.moved
	if u.moved == King || u.moved == -King {
		e.kings[us] = from
	}
	if u.captured != Empty {
		e.b[u.capSq] = u.captured
		e.restorePiece(them, u.capSq, u.capIdx)
	}
	e.castle, e.ep, e.half, e.score = u.castle, u.ep, u.half, u.score
}

// moveIsLegal is called right after make(m) (so e.turn is the opponent).
// wasInCheck says whether the mover was in check before m. A normal
// non-king move from a square not lined up with its own king cannot
// expose that king, so the attack test is skipped.
func (e *engine) moveIsLegal(m int, u undo, wasInCheck bool) bool {
	k := e.kings[1-e.turn]
	if !wasInCheck && u.special == 0 && u.moved != King && u.moved != -King &&
		geo[k*NumSquares+m&63]&geoLine == 0 {
		return true
	}
	return !e.attacked(k, e.turn)
}

// givesCheck is called right after make(m): does the side to move now
// stand in check? Cheap geometric filters avoid most attack tests.
func (e *engine) givesCheck(m int, u undo) bool {
	ek := e.kings[e.turn]
	from, to := m&63, (m>>6)&63
	g := ek * NumSquares
	maybe := u.special != 0 || geo[g+from]&geoLine != 0 // castling, e.p., discovery
	if !maybe {
		switch e.b[to].Type() {
		case Knight:
			maybe = geo[g+to]&geoKnight != 0
		case Pawn:
			maybe = geo[g+to]&geoKing != 0
		case King:
		default:
			maybe = geo[g+to]&geoLine != 0
		}
	}
	return maybe && e.attacked(ek, 1-e.turn)
}

// legal returns the legal moves (captures first) as encoded ints.
func (e *engine) legal() []int {
	pb := newPlyBuf()
	e.gen(pb, false)
	out := make([]int, 0, pb.nc+pb.nq)
	for i := 0; i < pb.nc+pb.nq; i++ {
		m := 0
		if i < pb.nc {
			m = pb.caps[i]
		} else {
			m = pb.quiets[i-pb.nc]
		}
		u := e.make(m)
		if !e.attacked(e.kings[1-e.turn], e.turn) {
			out = append(out, m)
		}
		e.unmake(m, u)
	}
	return out
}

// mix is a splitmix64-style mixer used to build position hashes.
func mix(x uint64) uint64 {
	x += 0x9e3779b97f4a7c15
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9
	x = (x ^ (x >> 27)) * 0x94d049bb133111eb
	return x ^ (x >> 31)
}

// hash is a Zobrist-style hash of the position (pieces, side to move,
// castling rights, en passant square), used to detect repetitions.
func (e *engine) hash() uint64 {
	var h uint64
	for c := 0; c < 2; c++ {
		for i := 0; i < e.pcount[c]; i++ {
			sq := e.plist[c][i]
			h ^= mix(uint64(int(e.b[sq]+6)*NumSquares + sq))
		}
	}
	return h ^ mix(uint64(1000+int(e.turn)+2*e.castle+32*(e.ep+1)))
}

// position converts the engine state back to a Position.
func (e *engine) position(fullmove int) Position {
	return Position{Board: e.b, Turn: e.turn, Castling: e.castle, EP: e.ep, Halfmove: e.half, Fullmove: fullmove}
}
