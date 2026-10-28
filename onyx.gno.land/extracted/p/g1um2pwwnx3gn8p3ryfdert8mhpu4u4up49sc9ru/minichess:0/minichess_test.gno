package minichess

import "testing"

func perft(p Position, depth int) int {
	if depth == 0 {
		return 1
	}
	if depth == 1 {
		return len(p.LegalMoves())
	}
	n := 0
	for _, m := range p.LegalMoves() {
		n += perft(p.Play(m), depth-1)
	}
	return n
}

func mustFEN(t *testing.T, fen string) Position {
	t.Helper()
	p, err := ParseFEN(fen)
	if err != nil {
		t.Fatalf("ParseFEN(%q): %v", fen, err)
	}
	return p
}

func mustMove(t *testing.T, s string) Move {
	t.Helper()
	m, err := ParseMove(s)
	if err != nil {
		t.Fatalf("ParseMove(%q): %v", s, err)
	}
	return m
}

func isLegal(t *testing.T, p Position, s string) bool {
	t.Helper()
	_, ok := p.FindLegal(mustMove(t, s))
	return ok
}

func TestStartPosition(t *testing.T) {
	p := NewGame()
	if got := p.FEN(); got != StartFEN {
		t.Fatalf("FEN round trip: got %q", got)
	}
	if p.PieceAt("e1") != King || p.PieceAt("d8") != -Queen {
		t.Fatalf("pieces misplaced")
	}
}

// Perft values cross-checked against python-chess. These positions cover
// castling, en passant, promotions, pins and discovered checks.
func TestPerft(t *testing.T) {
	cases := []struct {
		fen  string
		want []int
	}{
		{StartFEN, []int{20, 400, 8902}},
		{"r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", []int{48, 2039}},
		{"8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", []int{14, 191, 2812}},
		{"r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", []int{6, 264, 9467}},
		{"rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", []int{44, 1486}},
	}
	for _, c := range cases {
		p := mustFEN(t, c.fen)
		for d, w := range c.want {
			if got := perft(p, d+1); got != w {
				t.Fatalf("%s: perft(%d) = %d, want %d", c.fen, d+1, got, w)
			}
		}
	}
}

func TestParseMove(t *testing.T) {
	m := mustMove(t, "E7E8N")
	if m.Promo != Knight || m.String() != "e7e8n" {
		t.Fatalf("got %v", m)
	}
	for _, bad := range []string{"", "e2", "i1i2", "a1a9", "e7e8k", "e2e4qq"} {
		if _, err := ParseMove(bad); err == nil {
			t.Fatalf("ParseMove(%q) should fail", bad)
		}
	}
}

func TestStartMoves(t *testing.T) {
	p := NewGame()
	for _, s := range []string{"e2e4", "e2e3", "g1f3", "b1a3"} {
		if !isLegal(t, p, s) {
			t.Fatalf("%s should be legal", s)
		}
	}
	for _, s := range []string{"e2e5", "e1e2", "e1g1", "d1d3", "e7e5"} {
		if isLegal(t, p, s) {
			t.Fatalf("%s should be illegal", s)
		}
	}
	n := p.Play(mustMove(t, "e2e4"))
	if n.FEN() != "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1" {
		t.Fatalf("after e2e4: %s", n.FEN())
	}
}

func TestCastling(t *testing.T) {
	p := mustFEN(t, "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	n := p.Play(mustMove(t, "e1g1"))
	if n.PieceAt("g1") != King || n.PieceAt("f1") != Rook || n.PieceAt("h1") != Empty {
		t.Fatalf("king-side castle wrong: %s", n.FEN())
	}
	if n.Castling != CastleBK|CastleBQ {
		t.Fatalf("white rights should be gone: %s", n.FEN())
	}
	n = p.Play(mustMove(t, "e1c1"))
	if n.PieceAt("c1") != King || n.PieceAt("d1") != Rook || n.PieceAt("a1") != Empty {
		t.Fatalf("queen-side castle wrong: %s", n.FEN())
	}

	// f1 attacked by the rook on f8: cannot castle through it.
	p = mustFEN(t, "r3kr2/8/8/8/8/8/8/R3K2R w KQq - 0 1")
	if isLegal(t, p, "e1g1") || !isLegal(t, p, "e1c1") {
		t.Fatalf("castling through check")
	}
	// In check: no castling at all.
	p = mustFEN(t, "4r1k1/8/8/8/8/8/8/R3K2R w KQ - 0 1")
	if isLegal(t, p, "e1g1") || isLegal(t, p, "e1c1") {
		t.Fatalf("castling out of check")
	}
	// Moving a rook loses that side's right.
	p = mustFEN(t, "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	n = p.Play(mustMove(t, "h1h2"))
	if n.Castling != CastleWQ|CastleBK|CastleBQ {
		t.Fatalf("rook move rights: %s", n.FEN())
	}
}

func TestEnPassant(t *testing.T) {
	p := mustFEN(t, "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
	if !isLegal(t, p, "e5d6") {
		t.Fatalf("e5d6 en passant should be legal")
	}
	n := p.Play(mustMove(t, "e5d6"))
	if n.PieceAt("d5") != Empty || n.PieceAt("d6") != Pawn {
		t.Fatalf("en passant wrong: %s", n.FEN())
	}
	// Without the e.p. square the capture is not available.
	p = mustFEN(t, "4k3/8/8/3pP3/8/8/8/4K3 w - - 0 1")
	if isLegal(t, p, "e5d6") {
		t.Fatalf("e5d6 should be illegal without e.p. right")
	}
}

func TestPromotion(t *testing.T) {
	p := mustFEN(t, "8/P6k/8/8/8/8/8/4K3 w - - 0 1")
	lm, ok := p.FindLegal(mustMove(t, "a7a8"))
	if !ok || lm.Promo != Queen || p.Play(lm).PieceAt("a8") != Queen {
		t.Fatalf("a7a8 should promote to a queen")
	}
	lm, ok = p.FindLegal(mustMove(t, "a7a8n"))
	if !ok || p.Play(lm).PieceAt("a8") != Knight {
		t.Fatalf("under-promotion to knight failed")
	}
}

func TestGameEnd(t *testing.T) {
	// Fool's mate.
	if s := mustFEN(t, "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3").Status(); s != Checkmate {
		t.Fatalf("expected checkmate, got %s", s)
	}
	if s := mustFEN(t, "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").Status(); s != Stalemate {
		t.Fatalf("expected stalemate, got %s", s)
	}
	if s := mustFEN(t, "7k/8/8/8/8/8/8/2B1K3 w - - 0 1").Status(); s != InsufficientMaterial {
		t.Fatalf("K+B vs K should be a draw, got %s", s)
	}
	if s := mustFEN(t, "7k/8/8/8/8/8/8/R3K3 w - - 0 1").Status(); s != Ongoing {
		t.Fatalf("K+R vs K is not a draw, got %s", s)
	}
	if s := mustFEN(t, "7k/8/8/8/8/8/8/R3K3 w - - 100 80").Status(); s != FiftyMoveDraw {
		t.Fatalf("expected 50-move draw, got %s", s)
	}
	if NewGame().Status() != Ongoing {
		t.Fatalf("start should be ongoing")
	}
}

func TestBotFindsMateInOne(t *testing.T) {
	p := mustFEN(t, "6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1") // Ra8#
	for level := MinLevel; level <= MaxLevel; level++ {
		m, ok := BestMove(p, level, 0)
		if !ok || p.Play(m).Status() != Checkmate {
			t.Fatalf("level %d played %s, not mate", level, m)
		}
	}
}

func TestBotTakesHangingQueen(t *testing.T) {
	p := mustFEN(t, "4k3/8/8/3q4/4P3/8/8/4K3 w - - 0 1")
	for level := MinLevel; level <= MaxLevel; level++ {
		m, _ := BestMove(p, level, 0)
		if m.String() != "e4d5" {
			t.Fatalf("level %d played %s, want e4d5", level, m)
		}
	}
}

// The node budget is what bounds a bot reply's gas cost on-chain.
func TestBotRespectsNodeBudget(t *testing.T) {
	positions := []string{StartFEN, "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"}
	for _, fen := range positions {
		p := mustFEN(t, fen)
		for level := MinLevel; level <= MaxLevel; level++ {
			m, nodes, ok := search(p, level, 0)
			if !ok {
				t.Fatalf("no move for %s", fen)
			}
			if _, legal := p.FindLegal(m); !legal {
				t.Fatalf("level %d played illegal %s", level, m)
			}
			if nodes > Level(level).Budget+1 {
				t.Fatalf("level %d used %d nodes, budget %d", level, nodes, Level(level).Budget)
			}
		}
	}
}

func TestBotIsDeterministic(t *testing.T) {
	p := NewGame()
	a, _ := BestMove(p, 2, 42)
	b, _ := BestMove(p, 2, 42)
	if a != b {
		t.Fatalf("same inputs gave %s and %s", a, b)
	}
}

func TestBotPlaysLegalGame(t *testing.T) {
	p := NewGame()
	for ply := 0; ply < 40 && p.Status() == Ongoing; ply++ {
		m, ok := BestMove(p, 1, ply)
		if !ok {
			t.Fatalf("no move in ongoing position %s", p.FEN())
		}
		if _, legal := p.FindLegal(m); !legal {
			t.Fatalf("bot played illegal %s in %s", m, p.FEN())
		}
		p = p.Play(m)
	}
}
