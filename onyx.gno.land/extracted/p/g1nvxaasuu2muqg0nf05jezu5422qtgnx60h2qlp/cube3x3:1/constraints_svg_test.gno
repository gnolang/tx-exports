package cube3x3

import (
	"encoding/base64"
	"errors"
	"strings"
	"testing"
)

// This relation is an identity that the exact anti-inverse reduction keeps.
const constraintIdentity = "R U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'"
const checkerboardMoves = "R2 L2 U2 D2 F2 B2"

func requireBuiltinRule(t *testing.T, id string) ConstraintRule {
	t.Helper()
	rule, ok := BuiltinRule(id)
	if !ok || rule == nil || rule.ID() != id {
		t.Fatalf("missing built-in rule %q", id)
	}
	return rule
}

func TestNoHalfTurnsPhysicalFaceBypasses(t *testing.T) {
	rule := requireBuiltinRule(t, "no_half_turns")
	for _, raw := range []string{"R2", "Rw2", "R R", "R R'", "R Lw", "R x R", "R y2 L"} {
		moves := analyzerMoves(t, raw)
		if err := rule.Validate(MoveTrace{Moves: moves, PureMoves: ToPureFaceMoves(moves)}); err == nil {
			t.Errorf("no_half_turns accepted %q", raw)
		}
	}

	scramble := InvertMoves(analyzerMoves(t, "R Rw"))
	solution := constraintIdentity + " R Rw x2 y2 z2"
	got := VerifySolution(scramble, solution, rule)
	if !got.Valid || !got.Solved || got.OBTM != 26 || got.QTM != 26 {
		t.Errorf("no_half_turns rejected distinct physical faces or half rotations: %+v", got)
	}
}

func TestNoFBPhysicalFaceBypasses(t *testing.T) {
	rule := requireBuiltinRule(t, "no_fb")
	for _, raw := range []string{"F", "B'", "Fw", "Bw2", "x U x'", "y R y'", "Rw U Rw'"} {
		moves := analyzerMoves(t, raw)
		if err := rule.Validate(MoveTrace{Moves: moves, PureMoves: ToPureFaceMoves(moves)}); err == nil {
			t.Errorf("no_fb accepted %q", raw)
		}
	}
	scramble := analyzerMoves(t, "F'")
	if got := VerifySolution(scramble, constraintIdentity+" x U x'", rule); got.ErrorCode != "ERR_RULE_VIOLATION" {
		t.Errorf("no_fb verifier returned %+v for a finishing physical F turn", got)
	}
	if got := VerifySolution(nil, constraintIdentity+" x2 y2 z2", rule); !got.Valid {
		t.Errorf("no_fb rejected allowed physical faces: %+v", got)
	}
}

func TestPatternCheckerboardGenericTargetAndAntiInverse(t *testing.T) {
	rule := requireBuiltinRule(t, "pattern_checkerboard")
	target := rule.TargetAlg()
	if FormatMoves(target) != checkerboardMoves {
		t.Fatalf("checkerboard target = %q, want %q", FormatMoves(target), checkerboardMoves)
	}
	target[0] = Move{U, 1}
	if FormatMoves(rule.TargetAlg()) != checkerboardMoves {
		t.Fatal("checkerboard target was shared with the caller")
	}

	scramble := analyzerMoves(t, "R U")
	solution := constraintIdentity + " U' R' " + checkerboardMoves
	for _, tilt := range []string{"", " x", " x2", " x'", " z", " z'"} {
		for _, spin := range []string{"", " y", " y2", " y'"} {
			got := VerifySolution(scramble, solution+tilt+spin, rule)
			if !got.Valid || !got.Solved || got.Phases == nil {
				t.Errorf("checkerboard orientation %q: %+v", tilt+spin, got)
			}
		}
	}
	for _, tc := range []struct{ solution, code string }{
		{constraintIdentity + " U' R'", "ERR_NOT_SOLVED"},
		{"U' R' " + checkerboardMoves, "ERR_TRIVIAL_INVERSE"},
	} {
		got := VerifySolution(scramble, tc.solution, rule)
		if got.Valid || got.ErrorCode != tc.code || got.Phases != nil {
			t.Errorf("checkerboard solution %q: got %+v, want %s", tc.solution, got, tc.code)
		}
	}

	custom := testTargetRule{requireBuiltinRule(t, "wca_obtm")}
	if got := VerifySolution(nil, constraintIdentity+" F' x2", custom); !got.Valid {
		t.Errorf("non-checkerboard target was not verified: %+v", got)
	}
	if got := VerifySolution(nil, "F' x2", custom); got.ErrorCode != "ERR_TRIVIAL_INVERSE" {
		t.Errorf("custom target was not included in the anti-inverse check: %+v", got)
	}
}

type testTargetRule struct{ ConstraintRule }

func (testTargetRule) TargetAlg() []Move { return []Move{{F, 3}} }

type testMutatingTraceRule struct {
	ConstraintRule
	finalState Cube
}

func (rule testMutatingTraceRule) Validate(trace MoveTrace) error {
	if trace.FinalState != rule.finalState {
		return errors.New("unexpected final cube orientation in rule trace")
	}
	trace.Scramble[0] = Move{B, 2}
	trace.Moves[0] = Move{B, 2}
	trace.PureMoves[0] = Move{B, 2}
	trace.Phases.Segments[0] = PhaseSegment{Name: "changed"}
	return nil
}

func TestCloneTraceDeepCopiesSegmentsAndAllowedMoves(t *testing.T) {
	for _, tc := range []struct {
		id        string
		faceCount int
	}{
		{"wca_obtm", 18},
		{"checkpoint_cross_f2l", 18},
		{"pattern_checkerboard", 18},
		{"no_fb", 12},
		{"no_half_turns", 12},
	} {
		rule := requireBuiltinRule(t, tc.id)
		allowed := rule.AllowedMoves()
		if len(allowed) != tc.faceCount || len(rule.Title()) == 0 || len(rule.Description()) == 0 {
			t.Fatalf("invalid rule metadata or alphabet for %s", tc.id)
		}
		var seen [6][4]bool
		for _, move := range allowed {
			if move.Base > B || move.Mod < 1 || move.Mod > 3 {
				t.Fatalf("%s returned invalid alphabet move %v", tc.id, move)
			}
			if seen[move.Base][move.Mod] ||
				(tc.id == "no_fb" && (move.Base == F || move.Base == B)) ||
				(tc.id == "no_half_turns" && move.Mod == 2) {
				t.Errorf("%s returned unexpected alphabet move %v", tc.id, move)
			}
			seen[move.Base][move.Mod] = true
		}
		first := allowed[0]
		allowed[0] = Move{Z, 2}
		if rule.AllowedMoves()[0] != first {
			t.Errorf("%s shares its allowed-move slice", tc.id)
		}
		if tc.id != "pattern_checkerboard" && len(rule.TargetAlg()) != 0 {
			t.Errorf("%s should target the solved cube", tc.id)
		}
	}

	classic := requireBuiltinRule(t, "wca_obtm")
	finalState := ApplyMove(SolvedCube(), Move{X, 2})
	mutator := testMutatingTraceRule{classic, finalState}
	segment := PhaseSegment{"Cross", 1, 2, 2}
	original := MoveTrace{
		Scramble: []Move{{F, 1}}, Moves: []Move{{Rw, 1}}, PureMoves: []Move{{L, 1}},
		FinalState: finalState,
		Phases:     PhaseReport{Segments: []PhaseSegment{segment}},
	}
	if err := mutator.Validate(CloneTrace(original)); err != nil {
		t.Fatal(err)
	}
	if original.Scramble[0] != (Move{F, 1}) || original.Moves[0] != (Move{Rw, 1}) ||
		original.PureMoves[0] != (Move{L, 1}) || original.Phases.Segments[0] != segment {
		t.Fatalf("rule mutation escaped CloneTrace: %+v", original)
	}

	const finalTurns = "F R U R' U"
	scramble := InvertMoves(analyzerMoves(t, finalTurns))
	canonical, moves, err := Canonicalize(constraintIdentity + " " + finalTurns + " x2")
	if err != nil {
		t.Fatal(err)
	}
	want := VerifySolution(scramble, "  "+canonical+"\n", classic)
	if !want.Valid || want.Phases == nil || len(want.Phases.Segments) == 0 {
		t.Fatalf("verification fixture must pass with a phase segment: %+v", want)
	}
	got := VerifyCanonicalMoves(scramble, canonical, moves, mutator)
	if !got.Valid || !got.Solved || got.CanonicalMoves != want.CanonicalMoves ||
		got.OBTM != want.OBTM || got.QTM != want.QTM || got.Phases == nil ||
		len(got.Phases.Segments) != len(want.Phases.Segments) {
		t.Fatalf("canonical verifier returned %+v, want %+v", got, want)
	}
	if moves[0] != (Move{R, 1}) || scramble[0] != (Move{U, 3}) || got.Phases.Segments[0] != want.Phases.Segments[0] {
		t.Fatal("verification exposed caller moves or returned phase segments to the rule")
	}
}

func TestVerifySolution6ErrorCodesAndMaxTotalMoves(t *testing.T) {
	classic := requireBuiltinRule(t, "wca_obtm")
	half := requireBuiltinRule(t, "no_half_turns")
	checkpoint := requireBuiltinRule(t, "checkpoint_cross_f2l")
	for _, tc := range []struct {
		name, scramble, solution, code string
		rule                           ConstraintRule
	}{
		{"raw bytes", "", strings.Repeat(" ", 512) + "M", "ERR_INPUT_TOO_LONG", classic},
		{"invalid notation", "", "M", "ERR_INVALID_NOTATION", classic},
		{"zero OBTM", "", "x y z", "ERR_MOVE_LIMIT", classic},
		{"81 OBTM", "", strings.Repeat("R ", 81), "ERR_MOVE_LIMIT", classic},
		{"121 rotations", "", strings.Repeat("x ", 121), "ERR_MOVE_LIMIT", classic},
		{"121 tokens with valid OBTM", "", "R " + strings.Repeat("x ", 120), "ERR_MOVE_LIMIT", classic},
		{"wrong final state before rule", "", "R2", "ERR_NOT_SOLVED", half},
		{"trivial inverse before rule", "R2", "R2", "ERR_TRIVIAL_INVERSE", half},
		{"physical half turn", "", constraintIdentity + " R2 R2", "ERR_RULE_VIOLATION", half},
		{"missing checkpoint", "", constraintIdentity, "ERR_RULE_VIOLATION", checkpoint},
	} {
		got := VerifySolution(analyzerMoves(t, tc.scramble), tc.solution, tc.rule)
		if got.Valid || got.ErrorCode != tc.code || got.ErrorMessage == "" || got.Phases != nil {
			t.Errorf("%s: got %+v, want %s and nil phases", tc.name, got, tc.code)
		}
	}

	for _, tc := range []struct {
		cross, f2l int
		valid      bool
	}{{0, 4, false}, {4, 0, false}, {4, 4, false}, {4, 3, false}, {4, 5, true}} {
		trace := MoveTrace{Phases: PhaseReport{CrossAtMove: tc.cross, F2LAtMove: tc.f2l}}
		if got := checkpoint.Validate(trace) == nil; got != tc.valid {
			t.Errorf("Cross at %d, F2L at %d: valid=%t, want %t", tc.cross, tc.f2l, got, tc.valid)
		}
	}
	for _, tc := range []struct {
		day int64
		id  string
	}{
		{20782, "no_fb"}, {20783, "no_half_turns"}, {20799, "no_half_turns"},
		{-4, "checkpoint_cross_f2l"}, {-3, "pattern_checkerboard"}, {-2, "no_fb"}, {-1, "no_half_turns"},
		{0, "checkpoint_cross_f2l"}, {1, "pattern_checkerboard"},
	} {
		if got := DailyTwistedRule(tc.day).ID(); got != tc.id {
			t.Errorf("day %d: got %s, want %s", tc.day, got, tc.id)
		}
	}
	if rule, ok := BuiltinRule("unknown"); ok || rule != nil {
		t.Fatal("an unknown ID resolved as a built-in rule")
	}
}

func TestReplayReductionMatchesAntiInverseNormalization(t *testing.T) {
	for _, raw := range []string{
		"x y2 z'",
		"D U L R B F",
		"R L R' L' U",
		"R F U D U' D' F' R' L2",
		"R2 L R2 L L B2 B2 U' D R R' U",
		"x Rw2 U' B B' Uw2 y2 R L D2",
		constraintIdentity,
	} {
		moves := analyzerMoves(t, raw)
		got := reduceReplayTurns(ToPureFaceMoves(moves))
		want := NormalizePureFaceMoves(moves)
		if !sameMoveSequence(got, want) {
			t.Errorf("%q reduced to %q, want %q", raw, FormatMoves(got), FormatMoves(want))
		}
	}
}

const gasRotatedWide = "Rw2 x2 x2 Uw' x2 x2 Fw' x2 x2 "
const gasInverseWide = "Fw Uw Rw2 "
const gasWidePrefix = gasRotatedWide + gasRotatedWide + gasRotatedWide +
	gasRotatedWide + gasRotatedWide + gasRotatedWide + "Rw2 x2 x2 Uw' x2 x2 Fw' Rw2 Uw' "
const gasWidePrefixInverse = "Uw Rw2 " + gasInverseWide + gasInverseWide + gasInverseWide +
	gasInverseWide + gasInverseWide + gasInverseWide + gasInverseWide
const gasSingaporeSolve = "R F Rw Uw R' Fw' Uw' U2 R' Uw F' R2 U' F2 Uw F2 Uw2 Rw2 F2 R2 Uw' U'"

func TestVerifySolutionWorstCaseGas(t *testing.T) {
	// Follow the wide turns with their inverse so the nested turns cancel.
	const canonical = gasWidePrefix + "Fw' Rw2 Uw' Fw' Rw2 Uw' " +
		gasWidePrefixInverse + gasInverseWide + gasInverseWide + gasSingaporeSolve
	checkWorstCaseGasSolve(t, canonical, 108)
}

func TestVerifySolutionWorstCaseGasRetainedTurns(t *testing.T) {
	// Conjugating the wide-turn identity keeps more turns in the reduction.
	const wideCheckerboard = "Rw2 Lw2 Uw2 Dw2 Fw2 Bw2 "
	const canonical = gasWidePrefix + wideCheckerboard + wideCheckerboard +
		gasWidePrefixInverse + gasSingaporeSolve
	checkWorstCaseGasSolve(t, canonical, 116)
}

func checkWorstCaseGasSolve(t *testing.T, canonical string, qtm int) {
	t.Helper()
	// Both replays extend the sourced Singapore solve with 58 wide turns
	// and 40 rotations and pad the notation to the full byte limit.
	scramble := []Move{
		{R, 3}, {U, 3}, {F, 1}, {D, 1}, {R, 2}, {L, 3}, {U, 3}, {F, 1}, {L, 3},
		{U, 3}, {R, 2}, {B, 2}, {L, 1}, {B, 2}, {U, 3}, {L, 2}, {U, 2}, {D, 3},
		{R, 2}, {F, 2}, {L, 2}, {F, 3}, {R, 3}, {U, 3}, {F, 1},
	}
	if strings.Count(canonical, " ")+1 != MaxTotalMoves || len(canonical) > MaxRawMovesBytes {
		t.Fatal("gas fixture must hit the token cap and fit in the raw byte limit")
	}
	raw := canonical + strings.Repeat(" ", MaxRawMovesBytes-len(canonical))

	got := VerifySolution(scramble, raw, wcaOBTMRule{})
	if !got.Valid || !got.Solved || got.OBTM != MaxOBTM || got.QTM != qtm || got.CanonicalMoves != canonical || got.Phases == nil {
		t.Errorf("80-OBTM, 120-token, 512-byte solve failed: %+v", got)
	}
}

func TestSVGRenderMarkdownAndDataURI(t *testing.T) {
	const prefix = "data:image/svg+xml;base64,"
	state := ApplyMove(SolvedCube(), Move{R, 1})
	uri := RenderCubeNetDataURI(state)
	if !strings.HasPrefix(uri, prefix) {
		t.Fatalf("wrong SVG URI prefix: %.40s", uri)
	}
	if got := RenderCubeNetMarkdown(state, "Cube Net"); got != "![Cube Net]("+uri+")" {
		t.Fatal("markdown should wrap the same data URI exactly once")
	}
	data, err := base64.StdEncoding.DecodeString(uri[len(prefix):])
	if err != nil {
		t.Fatal(err)
	}
	svg := string(data)
	if !strings.HasPrefix(svg, "<svg ") || !strings.HasSuffix(svg, "</svg>") || strings.Count(svg, "<rect ") != 54 {
		t.Fatal("decoded image must contain one SVG net with 54 stickers")
	}
	if RenderCubeNetDataURI(SolvedCube()) == uri {
		t.Fatal("turning the cube should change the rendered facelets")
	}
}
