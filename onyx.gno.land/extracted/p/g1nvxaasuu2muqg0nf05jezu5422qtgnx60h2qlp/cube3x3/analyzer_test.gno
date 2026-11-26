package cube3x3

import "testing"

func TestToPureFaceMovesFrameTracking(t *testing.T) {
	start := ApplyMoves(SolvedCube(), analyzerMoves(t, "R U' B2 D F2 L'"))
	cases := []struct{ input, want string }{
		{"R x R", "R R"},
		{"R y2 L", "R R"},
		{"R Lw", "R R"},
		{"R Rw", "R L"},
		{"x U x'", "F"},
		{"y F y'", "R"},
		{"z U z'", "L"},
		{"Rw U Lw'", "L F R'"},
		{"R R' U2 U2", "R R' U2 U2"},
		{"x y2 z'", ""},
	}
	for _, tc := range cases {
		moves := analyzerMoves(t, tc.input)
		pure := ToPureFaceMoves(moves)
		if got := FormatMoves(pure); got != tc.want || len(pure) != len(analyzerMoves(t, tc.want)) {
			t.Errorf("%q projected to %q, want %q", tc.input, got, tc.want)
		}
		if ApplyMoves(start, pure) != NormalizeOrientation(ApplyMoves(start, moves)) {
			t.Errorf("%q changed the physical cube state", tc.input)
		}
	}

	// Every wide-turn modifier must also update the frame for subsequent turns.
	follow := analyzerMoves(t, "U D' F2 B R' L x2 z y' Rw2 U")
	for base := Uw; base <= Bw; base++ {
		for mod := uint8(1); mod <= 3; mod++ {
			moves := append([]Move{{base, mod}}, follow...)
			pure := ToPureFaceMoves(moves)
			obtm, _ := CountMetrics(moves)
			if len(pure) != obtm || ApplyMoves(start, pure) != NormalizeOrientation(ApplyMoves(start, moves)) {
				t.Errorf("base %d modifier %d: wrong physical sequence %q", base, mod, FormatMoves(pure))
			}
		}
	}
}

func TestAnalyzePhasesColorTrackedAcrossRotationsAndSkips(t *testing.T) {
	const crossAndF2L = "F R U R'"
	const sune = " R U R' U R U2 R'"
	const tPerm = " R U R' U' R' F R2 U' R' U' R U R' F'"
	const rotatedF2L = "F x2 y F D F'"
	const rotatedSune = " F D F' D F D2 F'"
	const rotatedTPerm = " F D F' D' F' R F2 D' F' D' F D F' R'"
	cases := []struct {
		name, physical, solution string
		checkpoints              [4]int
		segments                 []PhaseSegment
	}{
		{
			"rotated CFOP", crossAndF2L + sune + tPerm, rotatedF2L + rotatedSune + rotatedTPerm,
			[4]int{1, 6, 13, 27},
			[]PhaseSegment{{"Cross", 1, 1, 1}, {"F2L", 2, 6, 3}, {"OLL", 7, 13, 7}, {"PLL", 14, 27, 14}},
		},
		{
			"OLL skip", crossAndF2L + tPerm, rotatedF2L + rotatedTPerm,
			[4]int{1, 6, 6, 20},
			[]PhaseSegment{{"Cross", 1, 1, 1}, {"F2L", 2, 6, 3}, {"PLL", 7, 20, 14}},
		},
		{
			"PLL skip", crossAndF2L + sune, rotatedF2L + rotatedSune,
			[4]int{1, 6, 13, 13},
			[]PhaseSegment{{"Cross", 1, 1, 1}, {"F2L", 2, 6, 3}, {"OLL", 7, 13, 7}},
		},
		{
			"last layer oriented while F2L is broken", crossAndF2L + " D" + sune + " D'", crossAndF2L + " D" + sune + " D'",
			[4]int{1, 4, 13, 13},
			[]PhaseSegment{{"Cross", 1, 1, 1}, {"F2L", 2, 4, 3}, {"OLL", 5, 13, 9}},
		},
	}
	for _, tc := range cases {
		state := ApplyMoves(SolvedCube(), InvertMoves(analyzerMoves(t, tc.physical)))
		moves := analyzerMoves(t, tc.solution)
		if !IsSolved(ApplyMoves(state, moves)) {
			t.Fatalf("%s: fixture does not solve the cube", tc.name)
		}
		got := AnalyzePhases(state, moves)
		if got.CrossFace != "D" || got.CrossColor != 3 {
			t.Errorf("%s: cross face/color = %q/%d, want D/3", tc.name, got.CrossFace, got.CrossColor)
		}
		checkpoints := [4]int{got.CrossAtMove, got.F2LAtMove, got.OLLAtMove, got.PLLAtMove}
		if checkpoints != tc.checkpoints {
			t.Errorf("%s: checkpoints = %v, want %v", tc.name, checkpoints, tc.checkpoints)
		}
		if len(got.Segments) != len(tc.segments) {
			t.Errorf("%s: segments = %v, want %v", tc.name, got.Segments, tc.segments)
			continue
		}
		for i, segment := range got.Segments {
			if segment != tc.segments[i] {
				t.Errorf("%s: segment %d = %v, want %v", tc.name, i, segment, tc.segments[i])
			}
		}
	}
}

func TestAnalyzePhasesDirectSolve(t *testing.T) {
	state := ApplyMove(SolvedCube(), Move{F, 3})
	for _, solution := range []string{"F", "F x y", "x U x'"} {
		moves := analyzerMoves(t, solution)
		if !IsSolved(ApplyMoves(state, moves)) {
			t.Fatalf("%q: fixture does not solve the cube", solution)
		}
		got := AnalyzePhases(state, moves)
		if got.CrossFace != "" || got.CrossAtMove != 0 || got.F2LAtMove != 0 || got.OLLAtMove != 0 || got.PLLAtMove != len(moves) || len(got.Segments) != 0 {
			t.Errorf("%q: got %v, want only PLL at move %d", solution, got, len(moves))
		}
	}
}

func TestAnalyzePhasesAllCrossFaces(t *testing.T) {
	// The same solve in six frames puts the initial cross on each face in turn.
	for _, tc := range []struct {
		solution, face string
		color          uint8
	}{
		{"B R D R' D", "U", 0},
		{"F U L U' L", "R", 1},
		{"U R B R' B", "F", 2},
		{"F R U R' U", "D", 3},
		{"F D R D' R", "L", 4},
		{"D R F R' F", "B", 5},
	} {
		moves := analyzerMoves(t, tc.solution)
		state := ApplyMoves(SolvedCube(), InvertMoves(moves))
		got := AnalyzePhases(state, moves)
		if got.CrossFace != tc.face || got.CrossColor != tc.color || got.CrossAtMove != 1 || got.F2LAtMove != 4 || got.OLLAtMove != 4 || got.PLLAtMove != 5 {
			t.Errorf("%q: got %v, want cross face/color %s/%d and moves 1, 4, 4, 5", tc.solution, got, tc.face, tc.color)
		}
	}
}

func TestAnalyzePhasesPLLUsesTerminalSolvedRun(t *testing.T) {
	const solution = "F R U R' U"
	state := ApplyMoves(SolvedCube(), InvertMoves(analyzerMoves(t, solution)))
	for _, tc := range []struct {
		suffix string
		pll    PhaseSegment
	}{
		{" R R'", PhaseSegment{"PLL", 5, 7, 3}},
		{" R", PhaseSegment{}},
		{" R R' x y", PhaseSegment{"PLL", 5, 7, 3}},
	} {
		moves := analyzerMoves(t, solution+tc.suffix)
		wantSolved := tc.pll.EndMove > 0
		if IsSolved(ApplyMoves(state, moves)) != wantSolved {
			t.Fatalf("suffix %q: fixture should have solved=%t", tc.suffix, wantSolved)
		}
		wantSegments := []PhaseSegment{{"Cross", 1, 1, 1}, {"F2L", 2, 4, 3}}
		if wantSolved {
			wantSegments = append(wantSegments, tc.pll)
		}
		got := AnalyzePhases(state, moves)
		if got.PLLAtMove != tc.pll.EndMove {
			t.Errorf("suffix %q: PLL at %d, want %d", tc.suffix, got.PLLAtMove, tc.pll.EndMove)
		}
		if len(got.Segments) != len(wantSegments) {
			t.Errorf("suffix %q: segments = %v, want %v", tc.suffix, got.Segments, wantSegments)
			continue
		}
		for i, segment := range got.Segments {
			if segment != wantSegments[i] {
				t.Errorf("suffix %q: segment %d = %v, want %v", tc.suffix, i, segment, wantSegments[i])
			}
		}
	}
}

func TestNormalizeFixpointAndAntiInverse(t *testing.T) {
	start := ApplyMoves(SolvedCube(), analyzerMoves(t, "R U' B2 D F2 L'"))
	for _, tc := range []struct{ input, want string }{
		{"R L R'", "L"},
		{"R L R' L'", ""},
		{"R R'", ""},
		{"D U L R B F", "U D R L F B"},
		{"R F U D U' D' F' R'", ""},
		{"R2 L R2 L L", "L'"},
		{"x U x' F' y2", ""},
	} {
		moves := analyzerMoves(t, tc.input)
		normalized := NormalizePureFaceMoves(moves)
		if got := FormatMoves(normalized); got != tc.want {
			t.Errorf("normalize(%q) = %q, want %q", tc.input, got, tc.want)
		}
		if ApplyMoves(start, normalized) != NormalizeOrientation(ApplyMoves(start, moves)) {
			t.Errorf("normalize(%q) changed the physical cube state", tc.input)
		}
	}

	const checkerboard = "R2 L2 U2 D2 F2 B2"
	for _, tc := range []struct {
		scramble, solution, target string
		want                       bool
	}{
		{"R U", "U' R' x y", "", true},
		{"R U", "x y R' F'", "", true},
		{"R U", "U' x R'", "", true},
		{"R L R' L'", "x y L R L' R'", "", true},
		{"R U", "x y U' R'", "", false},
		{"R U", "U' R' " + checkerboard, checkerboard, true},
		{"R U", "U' R'", checkerboard, false},
		{"x R U", "U' R' U'", "F'", true},
		{
			"R' U' F D2 L2 F R2 U2 R2 B D2 L B2 D' B2 L' R' B D2 B U2 L U2 R' U' F",
			"D2 F' D2 U2 F' L2 D R2 D B2 F L2 R' F' D U'", "", false,
		},
	} {
		scramble := analyzerMoves(t, tc.scramble)
		solution := analyzerMoves(t, tc.solution)
		target := analyzerMoves(t, tc.target)
		if got := IsTrivialInverse(scramble, solution, target); got != tc.want {
			t.Errorf("IsTrivialInverse(%q, %q, %q) = %t, want %t", tc.scramble, tc.solution, tc.target, got, tc.want)
		}
	}
}

func analyzerMoves(t *testing.T, raw string) []Move {
	_, moves, err := Canonicalize(raw)
	if err != nil {
		t.Fatalf("invalid fixture %q: %v", raw, err)
	}
	return moves
}
