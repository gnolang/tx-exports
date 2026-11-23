package nandloom

import (
	"strings"
	"testing"
)

func buildReferenceRegistry(t *testing.T) (map[string]*Circuit, map[string]*CompiledCircuit) {
	t.Helper()
	circuits := make(map[string]*Circuit)
	compiled := make(map[string]*CompiledCircuit)
	resolve := func(slug string) (*Circuit, bool) {
		c, ok := circuits[slug]
		return c, ok
	}

	challenges := make(map[string]ChallengeSpec)
	for _, ch := range DefaultChallenges() {
		challenges[ch.ID] = ch
	}

	for _, ref := range DefaultReferenceChips() {
		ast, err := Parse(ref.Netlist)
		if err != nil {
			t.Fatalf("parse ref %s failed: %v", ref.Slug, err)
		}
		cc, err := Compile(ast, resolve)
		if err != nil {
			t.Fatalf("compile ref %s failed: %v", ref.Slug, err)
		}
		ch, ok := challenges[ref.ChallengeID]
		if !ok {
			t.Fatalf("missing challenge %s for ref %s", ref.ChallengeID, ref.Slug)
		}
		vr := Verify(cc, ch)
		if !vr.Passed {
			t.Fatalf("verify ref %s failed: %s", ref.Slug, vr.ErrorMessage)
		}
		circuits[ref.Slug] = ast
		compiled[ref.Slug] = cc
	}
	return circuits, compiled
}

func TestDefaultReferencesAndCompositionMetrics(t *testing.T) {
	_, compiled := buildReferenceRegistry(t)

	// Verify exact flattened NAND counts & depths through 4 levels of composition.
	cases := []struct {
		slug  string
		nands int
		depth int
		imps  int
	}{
		{"not1_ref", 1, 1, 0},
		{"and2_ref", 2, 2, 1},
		{"or2_ref", 3, 2, 1},
		{"xor2_ref", 4, 3, 0},
		{"mux2_ref", 4, 3, 1},
		{"half_adder_ref", 6, 3, 2},
		{"full_adder_ref", 15, 7, 2},
		{"adder4_ref", 60, 19, 1},
	}

	for _, tc := range cases {
		cc, ok := compiled[tc.slug]
		if !ok {
			t.Fatalf("missing compiled ref %s", tc.slug)
		}
		if cc.NANDCount != tc.nands {
			t.Errorf("%s: NANDCount got %d, want %d", tc.slug, cc.NANDCount, tc.nands)
		}
		if cc.MaxDepth != tc.depth {
			t.Errorf("%s: MaxDepth got %d, want %d", tc.slug, cc.MaxDepth, tc.depth)
		}
		if len(cc.ImportedChips) != tc.imps {
			t.Errorf("%s: ImportedChips got %d (%v), want %d", tc.slug, len(cc.ImportedChips), cc.ImportedChips, tc.imps)
		}
	}
}

func TestOptimalDesignsBeatReferenceRecords(t *testing.T) {
	circuits, _ := buildReferenceRegistry(t)
	resolve := func(slug string) (*Circuit, bool) {
		c, ok := circuits[slug]
		return c, ok
	}
	challenges := make(map[string]ChallengeSpec)
	for _, ch := range DefaultChallenges() {
		challenges[ch.ID] = ch
	}

	// 5-NAND shared-gate Half Adder (beats 6-NAND reference!)
	haOptNetlist := `
# Optimal 5-NAND Half Adder sharing w1 = nand(a, b)
in a, b
out sum, carry
w1 = nand(a, b)
w2 = nand(a, w1)
w3 = nand(b, w1)
sum = nand(w2, w3)
carry = nand(w1, w1)
`
	haAST, err := Parse(haOptNetlist)
	if err != nil {
		t.Fatalf("parse haOpt: %v", err)
	}
	haCC, err := Compile(haAST, resolve)
	if err != nil {
		t.Fatalf("compile haOpt: %v", err)
	}
	if vr := Verify(haCC, challenges["half_adder"]); !vr.Passed {
		t.Fatalf("verify haOpt failed: %s", vr.ErrorMessage)
	}
	if haCC.NANDCount != 5 || haCC.MaxDepth != 3 {
		t.Fatalf("haOpt metrics got (%d, %d), want (5, 3)", haCC.NANDCount, haCC.MaxDepth)
	}
	circuits["half_adder_opt"] = haAST

	// 9-NAND optimal Full Adder (beats 15-NAND reference!)
	faOptNetlist := `
# Optimal 9-NAND Full Adder
in a, b, cin
out sum, cout
w1 = nand(a, b)
w2 = nand(a, w1)
w3 = nand(b, w1)
w4 = nand(w2, w3)
w5 = nand(w4, cin)
w6 = nand(w4, w5)
w7 = nand(cin, w5)
sum = nand(w6, w7)
cout = nand(w5, w1)
`
	faAST, err := Parse(faOptNetlist)
	if err != nil {
		t.Fatalf("parse faOpt: %v", err)
	}
	faCC, err := Compile(faAST, resolve)
	if err != nil {
		t.Fatalf("compile faOpt: %v", err)
	}
	if vr := Verify(faCC, challenges["full_adder"]); !vr.Passed {
		t.Fatalf("verify faOpt failed: %s", vr.ErrorMessage)
	}
	if faCC.NANDCount != 9 || faCC.MaxDepth != 6 {
		t.Fatalf("faOpt metrics got (%d, %d), want (9, 6)", faCC.NANDCount, faCC.MaxDepth)
	}
	circuits["full_adder_opt"] = faAST

	// 36-NAND optimal 4-Bit Ripple Carry Adder composing 4x full_adder_opt!
	a4OptNetlist := `
in a0, a1, a2, a3, b0, b1, b2, b3, cin
out s0, s1, s2, s3, cout
s0, c1 = chip:full_adder_opt(a0, b0, cin)
s1, c2 = chip:full_adder_opt(a1, b1, c1)
s2, c3 = chip:full_adder_opt(a2, b2, c2)
s3, cout = chip:full_adder_opt(a3, b3, c3)
`
	a4AST, err := Parse(a4OptNetlist)
	if err != nil {
		t.Fatalf("parse a4Opt: %v", err)
	}
	a4CC, err := Compile(a4AST, resolve)
	if err != nil {
		t.Fatalf("compile a4Opt: %v", err)
	}
	if vr := Verify(a4CC, challenges["adder4"]); !vr.Passed {
		t.Fatalf("verify a4Opt failed: %s", vr.ErrorMessage)
	}
	if a4CC.NANDCount != 36 || a4CC.MaxDepth != 12 {
		t.Fatalf("a4Opt metrics got (%d, %d), want (36, 12)", a4CC.NANDCount, a4CC.MaxDepth)
	}

	// Live spot check: 15 + 0 + 1 = 16 -> s=0000, cout=1 -> "00001"
	tr, err := EvalBits(a4CC, "111100001")
	if err != nil {
		t.Fatalf("EvalBits failed: %v", err)
	}
	if tr.OutputBits != "00001" {
		t.Fatalf("15+0+1 got %s, want 00001", tr.OutputBits)
	}
}

func TestAdversarialRejections(t *testing.T) {
	// 1. Combinational 2-node cycle
	cyc, err := Parse("in a\nout y\nx = nand(a, y)\ny = nand(x, a)")
	if err != nil {
		t.Fatalf("unexpected parse err: %v", err)
	}
	if _, err := Compile(cyc, nil); err == nil || !strings.Contains(err.Error(), "cycle") {
		t.Fatalf("expected cycle error, got: %v", err)
	}

	// 2. Self-cycle
	selfCyc, err := Parse("in a\nout y\ny = nand(y, a)")
	if err != nil {
		t.Fatalf("unexpected parse err: %v", err)
	}
	if _, err := Compile(selfCyc, nil); err == nil || !strings.Contains(err.Error(), "cycle") {
		t.Fatalf("expected self-cycle error, got: %v", err)
	}

	// 3. Recursive chip import cycle
	cA, _ := Parse("in a\nout y\ny = chip:chip_b(a)")
	cB, _ := Parse("in a\nout y\ny = chip:chip_a(a)")
	reg := map[string]*Circuit{"chip_a": cA, "chip_b": cB}
	if _, err := Compile(cA, func(s string) (*Circuit, bool) { c, ok := reg[s]; return c, ok }); err == nil || !strings.Contains(err.Error(), "cycle") {
		t.Fatalf("expected recursive chip cycle error, got: %v", err)
	}

	// 4. Flattened gate cap exhaustion (> 128 NANDs hidden via nested sub-chips)
	// Build a 16-NAND dummy chip, then call it 9 times = 144 NANDs > 128 cap.
	var sb strings.Builder
	sb.WriteString("in a\nout y\nw0 = nand(a, a)\n")
	for i := 1; i < 15; i++ {
		sb.WriteString("w")
		sb.WriteString(itoaSimple(i))
		sb.WriteString(" = nand(w")
		sb.WriteString(itoaSimple(i - 1))
		sb.WriteString(", a)\n")
	}
	sb.WriteString("y = nand(w14, a)\n")
	big16, err := Parse(sb.String())
	if err != nil {
		t.Fatalf("parse big16: %v", err)
	}
	bombSrc := `in a
out y
w1 = chip:big16(a)
w2 = chip:big16(w1)
w3 = chip:big16(w2)
w4 = chip:big16(w3)
w5 = chip:big16(w4)
w6 = chip:big16(w5)
w7 = chip:big16(w6)
w8 = chip:big16(w7)
y = chip:big16(w8)`
	bombAST, err := Parse(bombSrc)
	if err != nil {
		t.Fatalf("parse bomb: %v", err)
	}
	if _, err := Compile(bombAST, func(s string) (*Circuit, bool) {
		if s == "big16" {
			return big16, true
		}
		return nil, false
	}); err == nil || !strings.Contains(err.Error(), "128") {
		t.Fatalf("expected max 128 gate cap error, got: %v", err)
	}

	// 5. Parser rejects invalid syntax, duplicate assignment, non-ASCII, bad ops
	badInputs := []string{
		"",
		"in a\nout y\ny = xor(a, a)",                 // unsupported op
		"in a\nout y\nw = nand(a, a)\nw = nand(a,a)", // duplicate wire
		"in a\nout y\na = nand(a, a)\ny = buf(a)",    // assigning input
		"in a\nout y\ny = nand(a)",                   // arity mismatch
		"in a\nout y\ny = nand(a, a)\n\x00",          // control byte
		"in _bad\nout y\ny = nand(_bad, _bad)",       // leading underscore reserved
	}
	for i, src := range badInputs {
		if _, err := Parse(src); err == nil {
			t.Errorf("badInput[%d] unexpectedly parsed cleanly", i)
		}
	}

	// 6. Wrong truth table caught with exact counterexample
	badXOR, _ := Parse("in a, b\nout y\ny = nand(a, b)")
	badCC, _ := Compile(badXOR, nil)
	challenges := DefaultChallenges()
	vr := Verify(badCC, challenges[3]) // xor2
	if vr.Passed {
		t.Fatalf("expected NAND to fail XOR challenge")
	}
	if vr.FailInput != "00" || vr.FailExpected != "0" || vr.FailActual != "1" {
		t.Fatalf("unexpected counterexample: in=%s exp=%s act=%s", vr.FailInput, vr.FailExpected, vr.FailActual)
	}
}

func TestSVGRenderingAndEscaping(t *testing.T) {
	_, compiled := buildReferenceRegistry(t)
	fa := compiled["full_adder_ref"]
	tr, err := EvalBits(fa, "111")
	if err != nil {
		t.Fatalf("eval full_adder_ref: %v", err)
	}
	if tr.OutputBits != "11" {
		t.Fatalf("1+1+1 got %s, want 11", tr.OutputBits)
	}

	rawSVG := RenderSchematicRawSVG(`Full <script>alert(1)</script> & Adder`, fa, tr)
	if !strings.HasPrefix(rawSVG, "<svg ") || !strings.HasSuffix(rawSVG, "</svg>") {
		t.Fatalf("invalid SVG wrapper")
	}
	if strings.Contains(rawSVG, "<script>") {
		t.Fatalf("SVG failed to escape <script> tag")
	}
	if !strings.Contains(rawSVG, "&lt;script&gt;") {
		t.Fatalf("expected escaped script text in SVG")
	}
	if !strings.Contains(rawSVG, "#10b981") {
		t.Fatalf("expected live HIGH wire highlight color in SVG")
	}
	if !strings.Contains(rawSVG, "IC · 6 NAND") {
		t.Fatalf("expected composite IC sub-chip badge in SVG")
	}

	mdImg := RenderSchematicSVG("Full Adder", fa, tr)
	if !strings.HasPrefix(mdImg, "![") || !strings.Contains(mdImg, "data:image/svg+xml;base64,") {
		t.Fatalf("unexpected Markdown SVG output: %s", mdImg[:60])
	}

	// Waveform rendering
	ch := DefaultChallenges()[6] // full_adder
	wfRaw := RenderWaveformRawSVG("full_adder_ref", fa, ch, 8)
	if !strings.HasPrefix(wfRaw, "<svg ") || !strings.Contains(wfRaw, "<polyline") {
		t.Fatalf("expected valid waveform SVG with polylines")
	}

	// Pure-Gno exporter
	exported := ExportGno("full_adder_ref", fa)
	if !strings.Contains(exported, "func ChipFullAdderRef(a, b, cin bool) (sum, cout bool)") {
		t.Fatalf("unexpected ExportGno signature:\n%s", exported)
	}
}

func itoaSimple(n int) string {
	if n == 0 {
		return "0"
	}
	var d []byte
	for n > 0 {
		d = append([]byte{byte('0' + n%10)}, d...)
		n /= 10
	}
	return string(d)
}
