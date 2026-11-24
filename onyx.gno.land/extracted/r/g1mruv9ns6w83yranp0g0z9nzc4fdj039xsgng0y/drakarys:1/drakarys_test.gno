package drakarys

import (
	"crypto/keccak256"
	"strconv"
	"strings"
	"testing"
)

// the realm gates calls on cur.Previous() == operator; in unit tests the
// test fn runs as the previous realm, so operator checks can't be faked
// through the public API - instead we test the game logic internals plus
// the JSON renderer (the e2e test in back/test_gno_chain.mjs covers the
// operator path against a real node).

func TestParseMove(t *testing.T) {
	fields := []string{"5"}
	for i := 0; i < 22; i++ {
		fields = append(fields, strconv.Itoa(i-11))
	}
	fields = append(fields, "3", "1")
	fields = append(fields, strings.Repeat("0", 62)+"ff")
	m := parseMove(strings.Join(fields, ","))
	if m.StateIdx != 5 {
		t.Fatalf("stateIdx %d", m.StateIdx)
	}
	if m.DeltaPlayerPositions[0][0] != -11 || m.DeltaPlayerPositions[10][1] != 10 {
		t.Fatalf("deltas %#v", m.DeltaPlayerPositions[0])
	}
	if m.Commands != [2]uint64{3, 1} {
		t.Fatalf("commands %#v", m.Commands)
	}
	if m.SeedPart[31] != 0xff {
		t.Fatalf("seed %#x", m.SeedPart)
	}
}

func TestKeccakPack(t *testing.T) {
	// verify our u256 packing produces the same 64-byte preimage the EVM
	// contract hashes for a round-0 (seed-only) commitment
	var enc []byte
	packU256(7, &enc)
	var seed [32]byte
	seed[31] = 0x2a
	enc = append(enc, seed[:]...)
	if len(enc) != 64 || enc[31] != 7 || enc[63] != 0x2a {
		t.Fatalf("packed %d %x", len(enc), enc)
	}
	h := keccak256.Sum256(enc)
	if h == [32]byte{} {
		t.Fatal("hash empty")
	}
}

func TestRngDeterministic(t *testing.T) {
	if rng(42) != rng(42) || rng(42) == 0 {
		t.Fatal("rng not deterministic")
	}
	if rng(1) == rng(2) {
		t.Fatal("rng constant")
	}
}

func TestSeedI64(t *testing.T) {
	var w [32]byte
	for i := 24; i < 32; i++ {
		w[i] = 0xff
	}
	if seedI64(w) != -1 {
		t.Fatalf("seedI64 %d", seedI64(w))
	}
	// 0x...ff >> 1 keeps all low bits
	w[23] = 0x01
	if seedI64Half(w) != -1 {
		t.Fatalf("seedI64Half %d", seedI64Half(w))
	}
}

func TestJsonRenderEmpty(t *testing.T) {
	// a match that has commits but no reveals renders skeleton JSON
	matches = map[string]*MatchEntry{}
	matchIDs = nil
	matches["3"] = &MatchEntry{
		MatchIdx: 3,
		Agents:   [2]string{"0xAAA", "0xBBB"},
	}
	matchIDs = append(matchIDs, 3)
	out := GetMatch(3)
	if !strings.Contains(out, `"match_idx":3`) ||
		!strings.Contains(out, `"0xAAA"`) ||
		!strings.Contains(out, `"ended":false`) {
		t.Fatalf("bad json: %s", out)
	}
	if GetMatchCount() != 1 {
		t.Fatalf("count %d", GetMatchCount())
	}
	ids := GetMatchIDs(0, 10)
	if ids != "[3]" {
		t.Fatalf("ids %s", ids)
	}
	if GetMatch(9) != "null" {
		t.Fatal("unknown match should render null")
	}
}


