package customrule_demo

import (
	"strings"
	"testing"

	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/cube3x3"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/bench"
)

func TestNoTopFaceTurnsReturnsFreshAllowedMoves(t *testing.T) {
	rule := noUFaceRule{}
	const alphabet = "D D2 D' L L2 L' R R2 R' F F2 F' B B2 B'"
	moves := rule.AllowedMoves()
	uassert.Equal(t, alphabet, cube3x3.FormatMoves(moves))
	if len(moves) != 15 {
		t.Fatalf("got %d allowed moves, want 15", len(moves))
	}
	moves[0] = cube3x3.Move{Base: cube3x3.U, Mod: 1}
	uassert.Equal(t, alphabet, cube3x3.FormatMoves(rule.AllowedMoves()))
	uassert.True(t, rule.TargetAlg() == nil)
	uassert.True(t, rule.Validate(cube3x3.MoveTrace{}) == nil)
}

func TestNoTopFaceTurnsAcrossRealms(cur realm, t *testing.T) {
	const ruleKey = "gno.land/r/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/customrule_demo:no_u_face"
	key := Register(cross(cur))
	uassert.Equal(t, ruleKey, key)
	today := bench.GetTodayJSON()
	if !strings.Contains(today, `{"ruleKey":"`+ruleKey+`","title":"No Top-Face Turns","isCustom":true}`) {
		t.Fatalf("custom rule missing from available rules: %s", today)
	}

	round := bench.StartQuickRound(cross(cur), key, 30, 30)
	detail := bench.GetChallengeJSON(round)
	const scrambleField = `,"scramble":"`
	start := strings.Index(detail, scrambleField)
	if start < 0 {
		t.Fatalf("custom round missing scramble: %s", detail)
	}
	scrambleJSON := detail[start+len(scrambleField):]
	end := strings.Index(scrambleJSON, `"`)
	if end <= 0 {
		t.Fatalf("custom round missing scramble text: %s", detail)
	}
	_, scramble, err := cube3x3.Canonicalize(scrambleJSON[:end])
	if err != nil {
		t.Fatalf("invalid custom round scramble: %v", err)
	}
	for _, move := range scramble {
		uassert.True(t, move.Base >= cube3x3.D && move.Base <= cube3x3.B)
	}

	// A full R/D commutator cycle preserves the target and survives the
	// trivial-inverse check. All of its turns are allowed by the rule.
	solve := strings.Repeat("R D R' D' ", 6) + cube3x3.FormatMoves(cube3x3.InvertMoves(scramble))
	for _, tc := range []struct {
		conjugate, physical string
	}{
		{"x F x'", "D"},
		{"x' F x", "U"},
	} {
		_, moves, err := cube3x3.Canonicalize(tc.conjugate)
		if err != nil {
			t.Fatal(err)
		}
		uassert.Equal(t, tc.physical, cube3x3.FormatMoves(cube3x3.ToPureFaceMoves(moves)))
	}
	for _, tc := range []struct {
		prefix, verdict string
	}{
		{"", `"valid":true,"errorCode":""`},
		{"x F x' x F' x' ", `"valid":true,"errorCode":""`},
		{"U U' ", `"valid":false,"errorCode":"ERR_RULE_VIOLATION"`},
		{"x' F x x' F' x ", `"valid":false,"errorCode":"ERR_RULE_VIOLATION"`},
	} {
		got := bench.VerifyDryRunJSON(round, tc.prefix+solve)
		if !strings.Contains(got, tc.verdict) || !strings.Contains(got, `"solved":true`) {
			t.Errorf("moves with prefix %q: want %s on a solved cube, got %s", tc.prefix, tc.verdict, got)
		}
	}
}
