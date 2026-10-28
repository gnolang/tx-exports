package minichess

import "testing"

// fastPerft walks the tree the way the search does (in-place make/unmake
// with the cheap legality and check filters) and cross-checks the filters
// against full attack tests at every node.
func fastPerft(t *testing.T, e *engine, depth, ply int, inCheck bool) int {
	if depth == 0 {
		return 1
	}
	pb := e.buf(ply)
	e.gen(pb, false)
	n := 0
	for i := 0; i < pb.nc+pb.nq; i++ {
		m := 0
		if i < pb.nc {
			m = pb.caps[i]
		} else {
			m = pb.quiets[i-pb.nc]
		}
		u := e.make(m)
		fast := e.moveIsLegal(m, u, inCheck)
		full := !e.attacked(e.kings[1-e.turn], e.turn)
		if fast != full {
			t.Fatalf("moveIsLegal mismatch for %s", decode(m))
		}
		if full {
			gc := e.givesCheck(m, u)
			if gc != e.inCheck() {
				t.Fatalf("givesCheck mismatch for %s", decode(m))
			}
			n += fastPerft(t, e, depth-1, ply+1, gc)
		}
		e.unmake(m, u)
	}
	return n
}

func TestFastPathPerft(t *testing.T) {
	cases := []struct {
		fen   string
		depth int
		want  int
	}{
		{"r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 2, 2039},
		{"8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 3, 2812},
		{"r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", 3, 9467},
		{"rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", 2, 1486},
	}
	for _, c := range cases {
		p := mustFEN(t, c.fen)
		e := newEngine(&p)
		before := p.FEN()
		if got := fastPerft(t, e, c.depth, 0, e.inCheck()); got != c.want {
			t.Fatalf("%s: got %d want %d", c.fen, got, c.want)
		}
		if after := e.position(p.Fullmove).FEN(); after != before {
			t.Fatalf("make/unmake did not restore: %s vs %s", after, before)
		}
	}
}
