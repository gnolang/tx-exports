package nandloom

import (
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestSeededStateAndHomeRender(t *testing.T) {
	if challenges.Size() != 8 {
		t.Fatalf("expected 8 seeded challenges, got %d", challenges.Size())
	}
	if chips.Size() != 8 {
		t.Fatalf("expected 8 seeded reference chips, got %d", chips.Size())
	}

	// Verify cross-chip reuse counters were automatically populated during seeding:
	// not1_ref is imported by and2_ref, or2_ref, mux2_ref -> 3 reuses.
	_, _, _, nands, depth, reuses, ok := GetChipInfo("not1_ref")
	if !ok || nands != 1 || depth != 1 || reuses != 3 {
		t.Fatalf("not1_ref unexpected info: ok=%v nands=%d depth=%d reuses=%d", ok, nands, depth, reuses)
	}

	// Home page renders featured live schematic SVG + all 8 challenges.
	home := Render("")
	if !strings.Contains(home, "data:image/svg+xml;base64,") {
		t.Fatalf("home render missing embedded SVG schematic")
	}
	if !strings.Contains(home, "4-Bit Ripple Carry Adder") || !strings.Contains(home, "adder4_ref") {
		t.Fatalf("home render missing featured adder4 challenge")
	}
}

func TestMultiUserSubmitBeatsRecordAndTracksReuse(cur realm, t *testing.T) {
	bob := testutils.TestAddress("bob")
	testing.SetRealm(testing.NewUserRealm(bob))

	// Bob submits an optimal 5-NAND Half Adder beating the 6-NAND reference!
	ha5 := `in a, b
out sum, carry
w1 = nand(a, b)
w2 = nand(a, w1)
w3 = nand(b, w1)
sum = nand(w2, w3)
carry = nand(w1, w1)`

	out := SubmitChip(cross(cur), "half_adder", "bob_ha5", "Bob 5-NAND Half Adder", "Shares nand(a,b).", ha5)
	if !strings.Contains(out, "NEW RECORD") || !strings.Contains(out, "5 NANDs") {
		t.Fatalf("expected NEW RECORD 5 NANDs, got: %s", out)
	}

	// Bob submits a 9-NAND Full Adder beating the 15-NAND reference!
	fa9 := `in a, b, cin
out sum, cout
w1 = nand(a, b)
w2 = nand(a, w1)
w3 = nand(b, w1)
w4 = nand(w2, w3)
w5 = nand(w4, cin)
w6 = nand(w4, w5)
w7 = nand(cin, w5)
sum = nand(w6, w7)
cout = nand(w5, w1)`

	out2 := SubmitChip(cross(cur), "full_adder", "bob_fa9", "Bob 9-NAND Full Adder", "Shared carry term.", fa9)
	if !strings.Contains(out2, "NEW RECORD") || !strings.Contains(out2, "9 NANDs") {
		t.Fatalf("expected NEW RECORD 9 NANDs, got: %s", out2)
	}

	// Alice composes Bob's verified chip:bob_fa9 to build a 36-NAND 4-bit adder!
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	a4Opt := `in a0, a1, a2, a3, b0, b1, b2, b3, cin
out s0, s1, s2, s3, cout
s0, c1 = chip:bob_fa9(a0, b0, cin)
s1, c2 = chip:bob_fa9(a1, b1, c1)
s2, c3 = chip:bob_fa9(a2, b2, c2)
s3, cout = chip:bob_fa9(a3, b3, c3)`

	out3 := SubmitChip(cross(cur), "adder4", "alice_adder36", "Alice 36-NAND Ripple Adder", "Composes 4x chip:bob_fa9.", a4Opt)
	if !strings.Contains(out3, "NEW RECORD") || !strings.Contains(out3, "36 NANDs") {
		t.Fatalf("expected NEW RECORD 36 NANDs, got: %s", out3)
	}

	// Verify bob_fa9 reuse count incremented to 1!
	_, _, _, _, _, faReuses, ok := GetChipInfo("bob_fa9")
	if !ok || faReuses != 1 {
		t.Fatalf("expected bob_fa9 reuse count 1, got %d (ok=%v)", faReuses, ok)
	}

	// Cross-realm EvalChip API check: 15 + 15 + 1 = 31 -> s=1111, cout=1 -> "11111"
	got := EvalChip("alice_adder36", "111111111")
	if got != "11111" {
		t.Fatalf("EvalChip(alice_adder36, 111111111) got %s, want 11111", got)
	}
}

func TestZeroWalletRenderSimulationAndSanitization(cur realm, t *testing.T) {
	// Zero-tx interactive bit toggle simulation on chip route
	page := Render("chip/half_adder_ref?in=11")
	if !strings.Contains(page, "11 -> 01") {
		t.Fatalf("expected live evaluation 11 -> 01 in chip page")
	}
	if !strings.Contains(page, "data:image/svg+xml;base64,") {
		t.Fatalf("expected embedded SVG schematic & waveform in chip page")
	}
	if !strings.Contains(page, "gno-button") {
		t.Fatalf("expected interactive bit-toggle buttons in chip page")
	}

	// Zero-wallet sandbox form query route
	sbPage := Render("sandbox?challenge=not1&bits=1&netlist=in+a%0Aout+y%0Ay+%3D+nand(a%2C+a)")
	if !strings.Contains(sbPage, "VERIFIED") {
		t.Fatalf("expected sandbox verification pass, got:\n%s", sbPage[:400])
	}

	// VerifyExternal read-only API
	okRes := VerifyExternal("not1", "in a\nout y\ny = nand(a, a)")
	if !strings.HasPrefix(okRes, "PASS|nands=1|depth=1|") {
		t.Fatalf("unexpected VerifyExternal PASS: %s", okRes)
	}
	badRes := VerifyExternal("not1", "in a\nout y\ny = buf(a)")
	if !strings.HasPrefix(badRes, "FAIL|") {
		t.Fatalf("expected VerifyExternal FAIL on identity gate, got: %s", badRes)
	}

	// Markdown injection test in title/notes
	mallory := testutils.TestAddress("mallory")
	testing.SetRealm(testing.NewUserRealm(mallory))
	SubmitChip(cross(cur), "not1", "mal_not", "Evil <gno-button href=\"http://bad\" /> | col", "Injected\n# Heading", "in a\nout y\ny = nand(a, a)")
	libPage := Render("chips")
	if strings.Contains(libPage, `<gno-button href="http://bad"`) {
		t.Fatalf("markdown/gno-button injection was not escaped in chips table")
	}

	// SnapshotJSON sanity check
	snap := SnapshotJSON()
	if !strings.HasPrefix(snap, "{") || !strings.Contains(snap, `"adder4"`) || !strings.Contains(snap, `"mal_not"`) {
		t.Fatalf("invalid SnapshotJSON output")
	}
}

func TestRejectsDuplicateAndBrokenCircuit(cur realm, t *testing.T) {
	u := testutils.TestAddress("tester")
	testing.SetRealm(testing.NewUserRealm(u))

	// Duplicate slug aborts atomically
	uassert.AbortsContains(t, cur, "already exists", func(cur realm) {
		SubmitChip(cross(cur), "not1", "not1_ref", "Dup", "", "in a\nout y\ny = nand(a, a)")
	})

	// Combinational cycle aborts atomically
	uassert.AbortsContains(t, cur, "cycle", func(cur realm) {
		SubmitChip(cross(cur), "not1", "cyc_not", "Cycle", "", "in a\nout y\nx = nand(a, y)\ny = nand(x, a)")
	})

	// Wrong truth table aborts with counterexample
	uassert.AbortsContains(t, cur, "verification failed", func(cur realm) {
		SubmitChip(cross(cur), "xor2", "bad_xor", "Broken XOR", "", "in a, b\nout y\ny = nand(a, b)")
	})
}
