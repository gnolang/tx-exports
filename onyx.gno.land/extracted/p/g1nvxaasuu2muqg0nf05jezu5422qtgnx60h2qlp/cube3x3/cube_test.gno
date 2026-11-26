package cube3x3

import "testing"

var superflipMoves = []Move{
	{U, 1}, {R, 2}, {F, 1}, {B, 1}, {R, 1}, {B, 2}, {R, 1}, {U, 2}, {L, 1}, {B, 2},
	{R, 1}, {U, 3}, {D, 3}, {R, 2}, {F, 1}, {R, 3}, {L, 1}, {B, 2}, {U, 2}, {F, 2},
}

func TestIndependentFaceletOracle(t *testing.T) {
	// These literals come from fixtures/cube-facelet-vectors.json.
	cases := []struct {
		name  string
		moves []Move
		want  string
	}{
		{"solved", nil, "UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB"},
		{"U", []Move{{U, 1}}, "UUUUUUUUUBBBRRRRRRRRRFFFFFFDDDDDDDDDFFFLLLLLLLLLBBBBBB"},
		{"U'", []Move{{U, 3}}, "UUUUUUUUUFFFRRRRRRLLLFFFFFFDDDDDDDDDBBBLLLLLLRRRBBBBBB"},
		{"U2", []Move{{U, 2}}, "UUUUUUUUULLLRRRRRRBBBFFFFFFDDDDDDDDDRRRLLLLLLFFFBBBBBB"},
		{"R", []Move{{R, 1}}, "UUFUUFUUFRRRRRRRRRFFDFFDFFDDDBDDBDDBLLLLLLLLLUBBUBBUBB"},
		{"R'", []Move{{R, 3}}, "UUBUUBUUBRRRRRRRRRFFUFFUFFUDDFDDFDDFLLLLLLLLLDBBDBBDBB"},
		{"R2", []Move{{R, 2}}, "UUDUUDUUDRRRRRRRRRFFBFFBFFBDDUDDUDDULLLLLLLLLFBBFBBFBB"},
		{"F", []Move{{F, 1}}, "UUUUUULLLURRURRURRFFFFFFFFFRRRDDDDDDLLDLLDLLDBBBBBBBBB"},
		{"F'", []Move{{F, 3}}, "UUUUUURRRDRRDRRDRRFFFFFFFFFLLLDDDDDDLLULLULLUBBBBBBBBB"},
		{"F2", []Move{{F, 2}}, "UUUUUUDDDLRRLRRLRRFFFFFFFFFUUUDDDDDDLLRLLRLLRBBBBBBBBB"},
		{"D", []Move{{D, 1}}, "UUUUUUUUURRRRRRFFFFFFFFFLLLDDDDDDDDDLLLLLLBBBBBBBBBRRR"},
		{"D'", []Move{{D, 3}}, "UUUUUUUUURRRRRRBBBFFFFFFRRRDDDDDDDDDLLLLLLFFFBBBBBBLLL"},
		{"D2", []Move{{D, 2}}, "UUUUUUUUURRRRRRLLLFFFFFFBBBDDDDDDDDDLLLLLLRRRBBBBBBFFF"},
		{"L", []Move{{L, 1}}, "BUUBUUBUURRRRRRRRRUFFUFFUFFFDDFDDFDDLLLLLLLLLBBDBBDBBD"},
		{"L'", []Move{{L, 3}}, "FUUFUUFUURRRRRRRRRDFFDFFDFFBDDBDDBDDLLLLLLLLLBBUBBUBBU"},
		{"L2", []Move{{L, 2}}, "DUUDUUDUURRRRRRRRRBFFBFFBFFUDDUDDUDDLLLLLLLLLBBFBBFBBF"},
		{"B", []Move{{B, 1}}, "RRRUUUUUURRDRRDRRDFFFFFFFFFDDDDDDLLLULLULLULLBBBBBBBBB"},
		{"B'", []Move{{B, 3}}, "LLLUUUUUURRURRURRUFFFFFFFFFDDDDDDRRRDLLDLLDLLBBBBBBBBB"},
		{"B2", []Move{{B, 2}}, "DDDUUUUUURRLRRLRRLFFFFFFFFFDDDDDDUUURLLRLLRLLBBBBBBBBB"},
		{"x", []Move{{X, 1}}, "FFFFFFFFFRRRRRRRRRDDDDDDDDDBBBBBBBBBLLLLLLLLLUUUUUUUUU"},
		{"y", []Move{{Y, 1}}, "UUUUUUUUUBBBBBBBBBRRRRRRRRRDDDDDDDDDFFFFFFFFFLLLLLLLLL"},
		{"z", []Move{{Z, 1}}, "LLLLLLLLLUUUUUUUUUFFFFFFFFFRRRRRRRRRDDDDDDDDDBBBBBBBBB"},
		{"Rw", []Move{{Rw, 1}}, "UFFUFFUFFRRRRRRRRRFDDFDDFDDDBBDBBDBBLLLLLLLLLUUBUUBUUB"},
		{"Superflip", superflipMoves, "UBULURUFURURFRBRDRFUFLFRFDFDFDLDRDBDLULBLFLDLBUBRBLBDB"},
	}
	for _, tc := range cases {
		got := CubeToFaceletString(ApplyMoves(SolvedCube(), tc.moves))
		if got != tc.want {
			t.Errorf("%s: got %s, want %s", tc.name, got, tc.want)
		}
	}
}

func TestBaseMoveIdentities(t *testing.T) {
	solved := SolvedCube()
	for _, base := range []uint8{U, D, L, R, F, B, Uw, Dw, Lw, Rw, Fw, Bw, X, Y, Z} {
		quarter := Move{base, 1}
		half := Move{base, 2}
		inverse := Move{base, 3}
		if ApplyMoves(solved, []Move{quarter, quarter, quarter, quarter}) != solved {
			t.Errorf("base %d: four quarter turns must return to solved", base)
		}
		if ApplyMoves(solved, []Move{quarter, inverse}) != solved {
			t.Errorf("base %d: a quarter turn followed by its inverse must return to solved", base)
		}
		if ApplyMoves(solved, []Move{half, half}) != solved {
			t.Errorf("base %d: two half turns must return to solved", base)
		}
	}
}

func TestWideMoveSanityEquivalences(t *testing.T) {
	c := ApplyMoves(SolvedCube(), []Move{{R, 1}, {U, 3}, {B, 2}, {D, 1}, {F, 2}})
	cases := []struct {
		wide uint8
		face Move
		spin Move
	}{
		{Rw, Move{L, 1}, Move{X, 1}},
		{Lw, Move{R, 1}, Move{X, 3}},
		{Uw, Move{D, 1}, Move{Y, 1}},
		{Dw, Move{U, 1}, Move{Y, 3}},
		{Fw, Move{B, 1}, Move{Z, 1}},
		{Bw, Move{F, 1}, Move{Z, 3}},
	}
	for _, tc := range cases {
		want := c
		for mod := uint8(1); mod <= 3; mod++ {
			want = ApplyMoves(want, []Move{tc.face, tc.spin})
			if ApplyMove(c, Move{tc.wide, mod}) != want {
				t.Errorf("base %d, modifier %d: wide turn must match its face turn and rotation", tc.wide, mod)
			}
		}
	}
}

func TestCubeGroupOrders(t *testing.T) {
	solved := SolvedCube()
	cases := []struct {
		name  string
		moves []Move
		order int
	}{
		{"R U R' U'", []Move{{R, 1}, {U, 1}, {R, 3}, {U, 3}}, 6},
		{"R U", []Move{{R, 1}, {U, 1}}, 105},
		{"T-Perm", []Move{
			{R, 1}, {U, 1}, {R, 3}, {U, 3}, {R, 3}, {F, 1}, {R, 2},
			{U, 3}, {R, 3}, {U, 3}, {R, 1}, {U, 1}, {R, 3}, {F, 3},
		}, 2},
		{"Superflip", superflipMoves, 2},
	}
	for _, tc := range cases {
		c := solved
		for n := 1; n <= tc.order; n++ {
			c = ApplyMoves(c, tc.moves)
			if (c == solved) != (n == tc.order) {
				t.Fatalf("%s: unexpected solved status at repetition %d, want order %d", tc.name, n, tc.order)
			}
		}
	}

	flipped := ApplyMoves(solved, superflipMoves)
	for i := range solved {
		if i%9%2 == 0 && flipped[i] != solved[i] {
			t.Errorf("superflip changed corner or center facelet %d", i)
		}
	}
	// Each pair is the two facelet indices of a single edge in URFDLB layout.
	edges := [12][2]int{
		{5, 10}, {7, 19}, {3, 37}, {1, 46},
		{32, 16}, {28, 25}, {30, 43}, {34, 52},
		{23, 12}, {21, 41}, {50, 39}, {48, 14},
	}
	for _, edge := range edges {
		a, b := edge[0], edge[1]
		if flipped[a] != solved[b] || flipped[b] != solved[a] {
			t.Errorf("superflip did not flip edge at facelets %d and %d", a, b)
		}
	}
}

func TestNormalizeOrientationAll24Frames(t *testing.T) {
	solved := SolvedCube()
	moves := []Move{{R, 1}, {U, 3}, {B, 2}, {D, 1}, {F, 2}, {L, 3}}
	want := ApplyMoves(solved, moves)
	if IsSolved(want) {
		t.Fatal("scrambled state reported as solved")
	}

	// Tilt each face to U, then rotate through four front faces.
	var seen [6][6]bool
	type framePair struct {
		solved    Cube
		scrambled Cube
	}
	frames := []framePair{{solved, want}}
	tilts := []Move{{X, 1}, {X, 2}, {X, 3}, {Z, 1}, {Z, 3}}
	for _, tilt := range tilts {
		frames = append(frames, framePair{ApplyMove(solved, tilt), ApplyMove(want, tilt)})
	}
	for _, frame := range frames {
		for spin := 0; spin < 4; spin++ {
			up, front := frame.scrambled[4], frame.scrambled[22]
			if seen[up][front] {
				t.Fatalf("duplicate frame with U=%d, F=%d", up, front)
			}
			seen[up][front] = true
			got := NormalizeOrientation(frame.scrambled)
			if got != want || got[4] != 0 || got[22] != 2 {
				t.Errorf("wrong normalization for U=%d, F=%d: %s", up, front, CubeToFaceletString(got))
			}
			if !IsSolved(frame.solved) || IsSolved(frame.scrambled) {
				t.Errorf("incorrect solved status for U=%d, F=%d", up, front)
			}
			frame.scrambled = ApplyMove(frame.scrambled, Move{Y, 1})
			frame.solved = ApplyMove(frame.solved, Move{Y, 1})
		}
	}
}
