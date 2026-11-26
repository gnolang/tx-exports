package cube3x3

import (
	"strings"
	"testing"
)

func TestCanonicalizeSharedVectors(t *testing.T) {
	// Canonicalization and metric cases from fixtures/wca-notation-vectors.json.
	valid := []struct {
		name, input, expected string
		obtm, qtm             int
	}{
		{"empty", "", "", 0, 0},
		{"ASCII whitespace only", " \t\n\r ", "", 0, 0},
		{"ASCII separators", " \tR   U2\nF'\r\nD\rL2 B' ", "R U2 F' D L2 B'", 6, 8},
		{"wide turns", "Uw Dw' Lw2 Rw Fw' Bw2", "Uw Dw' Lw2 Rw Fw' Bw2", 6, 8},
		{"mixed wide turns and rotations", "Rw x2\tF2 y' Lw2 z U'", "Rw x2 F2 y' Lw2 z U'", 4, 6},
		{"rotations only", "x y2 z'", "x y2 z'", 0, 0},
	}
	for _, tc := range valid {
		canonical, moves, err := Canonicalize(tc.input)
		if err != nil || canonical != tc.expected {
			t.Errorf("%s: got %q, %v, want %q", tc.name, canonical, err, tc.expected)
			continue
		}
		if tc.expected == "" && moves != nil {
			t.Errorf("%s: empty input should return nil moves", tc.name)
		}
		if formatted := FormatMoves(moves); formatted != tc.expected {
			t.Errorf("%s: formatted %q, want %q", tc.name, formatted, tc.expected)
		}
		obtm, qtm := CountMetrics(moves)
		if obtm != tc.obtm || qtm != tc.qtm {
			t.Errorf("%s: got OBTM/QTM %d/%d, want %d/%d", tc.name, obtm, qtm, tc.obtm, tc.qtm)
		}
	}

	invalid := []string{
		"M", "E", "S", "r", "u", "f", "R2'", "R'2", "Rw R'w", "X", "RU",
		"R\vU", "R\fU", "R\x00U", "R\x7fU", "R’", "R\u00a0U",
	}
	for _, input := range invalid {
		canonical, moves, err := Canonicalize(input)
		if err == nil || err.Error() != "ERR_INVALID_NOTATION" || canonical != "" || moves != nil {
			t.Errorf("%q: want ERR_INVALID_NOTATION and no output, got %q, %v, %v", input, canonical, moves, err)
		}
	}

	atLimit := strings.Repeat(" ", 511) + "R"
	canonical, moves, err := Canonicalize(atLimit)
	if err != nil || canonical != "R" || len(moves) != 1 {
		t.Fatalf("512 bytes: got %q, %v, %v", canonical, moves, err)
	}
	for _, input := range []string{atLimit + " ", strings.Repeat(" ", 511) + "é"} {
		canonical, moves, err := Canonicalize(input)
		if err == nil || err.Error() != "ERR_INPUT_TOO_LONG" || canonical != "" || moves != nil {
			t.Errorf("513 bytes: want ERR_INPUT_TOO_LONG and no output, got %q, %v, %v", canonical, moves, err)
		}
	}
}

func TestInvertMoves(t *testing.T) {
	moves := []Move{{R, 1}, {Uw, 2}, {X, 3}, {F, 1}}
	inverse := InvertMoves(moves)
	if got := FormatMoves(inverse); got != "F' x Uw2 R'" {
		t.Errorf("inverse = %q, want F' x Uw2 R'", got)
	}
	if got := FormatMoves(moves); got != "R Uw2 x' F" {
		t.Errorf("original moves changed to %q", got)
	}
	if ApplyMoves(ApplyMoves(SolvedCube(), moves), inverse) != SolvedCube() {
		t.Error("inverse did not restore the original facelets")
	}
}

func TestSourcedGoldenWCASolves(t *testing.T) {
	// These sequences and metrics come from fixtures/wca-golden-solves.json.
	cases := []struct {
		id, scramble, solution string
		obtm, qtm              int
	}{
		{
			"fmc2019-tronto-final-1",
			"R' U' F D2 L2 F R2 U2 R2 B D2 L B2 D' B2 L' R' B D2 B U2 L U2 R' U' F",
			"D2 F' D2 U2 F' L2 D R2 D B2 F L2 R' F' D U'",
			16, 23,
		},
		{
			"singapore2025-chang-first-1",
			"R' U' F D R2 L' U' F L' U' R2 B2 L B2 U' L2 U2 D' R2 F2 L2 F' R' U' F",
			"R F Rw Uw R' Fw' Uw' U2 R' Uw F' R2 U' F2 Uw F2 Uw2 Rw2 F2 R2 Uw' U'",
			22, 30,
		},
		{
			"warszawa2026-pietrusiak-final-3",
			"R' U' F R2 B U2 B' F L2 F U2 B' D' B' R2 U B2 F L D2 L2 F' R' U' F",
			"U B L U2 F' R' B' D2 B' L2 D2 F2 B' R2 B' R2 L2 D' F'",
			19, 27,
		},
	}
	for _, tc := range cases {
		_, scramble, err := Canonicalize(tc.scramble)
		if err != nil {
			t.Fatalf("%s: invalid scramble: %v", tc.id, err)
		}
		_, solution, err := Canonicalize(tc.solution)
		if err != nil || len(solution) == 0 {
			t.Fatalf("%s: invalid or empty solution: %v", tc.id, err)
		}
		obtm, qtm := CountMetrics(solution)
		if obtm != tc.obtm || qtm != tc.qtm {
			t.Errorf("%s: got OBTM/QTM %d/%d, want %d/%d", tc.id, obtm, qtm, tc.obtm, tc.qtm)
		}
		scrambled := ApplyMoves(SolvedCube(), scramble)
		if !IsSolved(ApplyMoves(scrambled, solution)) {
			t.Errorf("%s: reconstruction did not solve the scramble", tc.id)
		}
		if IsSolved(ApplyMoves(scrambled, solution[:len(solution)-1])) {
			t.Errorf("%s: reconstruction still solved without its final move", tc.id)
		}
	}
}

func TestScrambleDeterminismAndSubgroupGuards(t *testing.T) {
	for _, seed := range [][32]byte{{}, {1}, {255, 1}, {31: 255}} {
		wca := GenerateWCAScramble(seed)
		if len(wca) != 30 {
			t.Fatalf("WCA scramble length = %d, want 30", len(wca))
		}
		if FormatMoves(wca[:3]) != "R' U' F" || FormatMoves(wca[27:]) != "R' U' F" {
			t.Errorf("incorrect WCA scramble padding: %s", FormatMoves(wca))
		}
		if wca[3].Base == F || wca[3].Base == B || wca[26].Base == L || wca[26].Base == R {
			t.Errorf("WCA scramble has parallel turns at a padding seam: %s", FormatMoves(wca))
		}
		for _, move := range wca {
			if move.Base > B || move.Mod < 1 || move.Mod > 3 {
				t.Errorf("invalid WCA scramble move: %v", move)
			}
		}
		assertNoRedundantFaceTurns(t, wca)
		for _, rule := range []string{"wca_obtm", "checkpoint_cross_f2l", "pattern_checkerboard"} {
			got, err := ScrambleForRule(seed, rule, []Move{{X, 1}})
			if err != nil || FormatMoves(got) != FormatMoves(wca) {
				t.Errorf("%s did not reproduce the WCA scramble: %v", rule, err)
			}
		}

		for _, rule := range []string{"no_fb", "no_half_turns"} {
			got, err := ScrambleForRule(seed, rule, nil)
			if err != nil || len(got) != 35 {
				t.Fatalf("%s: want 35 moves, got %d, %v", rule, len(got), err)
			}
			for _, move := range got {
				if move.Base > B || move.Mod < 1 || move.Mod > 3 {
					t.Errorf("%s: invalid scramble move %v", rule, move)
				}
				if (rule == "no_fb" && (move.Base == F || move.Base == B)) ||
					(rule == "no_half_turns" && move.Mod == 2) {
					t.Errorf("%s: forbidden scramble move %v", rule, move)
				}
			}
			assertNoRedundantFaceTurns(t, got)
		}
	}

	if FormatMoves(GenerateWCAScramble([32]byte{})) == FormatMoves(GenerateWCAScramble([32]byte{1})) {
		t.Error("different seeds produced the same WCA scramble")
	}
	for _, bad := range [][]Move{
		{{R, 1}, {R, 3}, {L, 1}},
		{{X, 1}, {Y, 1}},
		{{R, 1}, {Rw, 3}, {U, 0}},
	} {
		if moves, err := GenerateSubgroupScramble([32]byte{}, bad, 35); err == nil || moves != nil {
			t.Errorf("invalid alphabet %v: want error and nil moves, got %v, %v", bad, moves, err)
		}
	}
}

func TestCustomSubgroupScramble(t *testing.T) {
	seed := [32]byte{7}
	clean := []Move{{U, 3}, {Rw, 2}}
	withDuplicates := []Move{{Y, 2}, {Rw, 2}, {U, 3}, {Rw, 2}, {U, 3}}
	want, err := GenerateSubgroupScramble(seed, clean, 35)
	if err != nil || len(want) != 35 {
		t.Fatalf("clean alphabet: want 35 moves, got %d, %v", len(want), err)
	}
	got, err := ScrambleForRule(seed, "custom", withDuplicates)
	if err != nil || FormatMoves(got) != FormatMoves(want) {
		t.Errorf("custom rule did not use the deduplicated subgroup: %v", err)
	}
	got, err = GenerateSubgroupScramble(seed, withDuplicates, 0)
	if err != nil || FormatMoves(got) != FormatMoves(want) {
		t.Errorf("default length did not produce the 35-move subgroup: %v", err)
	}
	short, err := GenerateSubgroupScramble(seed, clean, 6)
	const fromRight = "Rw2 U' Rw2 U' Rw2 U'"
	const fromUp = "U' Rw2 U' Rw2 U' Rw2"
	if formatted := FormatMoves(short); err != nil || (formatted != fromRight && formatted != fromUp) {
		t.Errorf("short custom scramble: expected alternating Rw2/U', got %q, %v", formatted, err)
	}
	if moves, err := GenerateSubgroupScramble(seed, clean, -1); err == nil || moves != nil {
		t.Errorf("negative length: want error and nil moves, got %v, %v", moves, err)
	}

	full := []Move{{U, 1}, {R, 1}, {Rw, 2}, {L, 3}}
	withExtras := []Move{{Z, 1}, {L, 3}, {Rw, 2}, {R, 1}, {Rw, 2}, {U, 1}, {R, 1}}
	want, err = GenerateSubgroupScramble(seed, full, 35)
	if err != nil || len(want) != 35 {
		t.Fatalf("custom alphabet: want 35 moves, got %d, %v", len(want), err)
	}
	got, err = GenerateSubgroupScramble(seed, withExtras, 35)
	if err != nil || FormatMoves(got) != FormatMoves(want) {
		t.Errorf("input ordering, duplicates, or rotations changed sampling: %v", err)
	}
	for i := 1; i < len(want); i++ {
		a, b := want[i-1].Base, want[i].Base
		if (a == R && b == Rw) || (a == Rw && b == R) {
			t.Errorf("custom scramble repeated a nominal face: %s", FormatMoves(want))
			break
		}
	}
}

func assertNoRedundantFaceTurns(t *testing.T, moves []Move) {
	for i := 1; i < len(moves); i++ {
		current, previous := moves[i].Base, moves[i-1].Base
		if current == previous {
			t.Errorf("consecutive same-face turns at %d: %s", i, FormatMoves(moves))
		}
		if i > 1 && current == moves[i-2].Base && current/2 == previous/2 {
			t.Errorf("parallel-axis ABA at %d: %s", i, FormatMoves(moves))
		}
	}
}
