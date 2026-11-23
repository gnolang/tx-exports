package nandloom

import "gno.land/p/nt/ufmt/v0"

// DefaultChallenges returns the 8 progressive NAND-to-4-Bit-Adder challenges.
// Every test vector is deterministic and capped at <= 64 vectors for bounded gas.
func DefaultChallenges() []ChallengeSpec {
	return []ChallengeSpec{
		{
			ID:         "not1",
			Title:      "Inverter (NOT)",
			Summary:    "Invert a single bit using universal NAND logic.",
			Difficulty: "Tier 1 · Foundations",
			Inputs:     []string{"a"},
			Outputs:    []string{"y"},
			ParNANDs:   1,
			ParDepth:   1,
			Vectors: []TestVector{
				{In: []bool{false}, Out: []bool{true}, Label: "0->1"},
				{In: []bool{true}, Out: []bool{false}, Label: "1->0"},
			},
			StarterNetlist: "in a\nout y\ny = nand(a, a)",
		},
		{
			ID:         "and2",
			Title:      "2-Input AND",
			Summary:    "Output 1 only when both a and b are 1. Try reusing chip:not1_ref.",
			Difficulty: "Tier 1 · Foundations",
			Inputs:     []string{"a", "b"},
			Outputs:    []string{"y"},
			ParNANDs:   2,
			ParDepth:   2,
			Vectors: []TestVector{
				{In: []bool{false, false}, Out: []bool{false}, Label: "00"},
				{In: []bool{false, true}, Out: []bool{false}, Label: "01"},
				{In: []bool{true, false}, Out: []bool{false}, Label: "10"},
				{In: []bool{true, true}, Out: []bool{true}, Label: "11"},
			},
			StarterNetlist: "in a, b\nout y\nw = nand(a, b)\ny = chip:not1_ref(w)",
		},
		{
			ID:         "or2",
			Title:      "2-Input OR",
			Summary:    "Output 1 when either a or b is 1 via De Morgan's law.",
			Difficulty: "Tier 1 · Foundations",
			Inputs:     []string{"a", "b"},
			Outputs:    []string{"y"},
			ParNANDs:   3,
			ParDepth:   2,
			Vectors: []TestVector{
				{In: []bool{false, false}, Out: []bool{false}, Label: "00"},
				{In: []bool{false, true}, Out: []bool{true}, Label: "01"},
				{In: []bool{true, false}, Out: []bool{true}, Label: "10"},
				{In: []bool{true, true}, Out: []bool{true}, Label: "11"},
			},
			StarterNetlist: "in a, b\nout y\nna = chip:not1_ref(a)\nnb = chip:not1_ref(b)\ny = nand(na, nb)",
		},
		{
			ID:         "xor2",
			Title:      "2-Input XOR",
			Summary:    "Output 1 when inputs differ. Can be solved cleanly in 4 NANDs.",
			Difficulty: "Tier 2 · Gates",
			Inputs:     []string{"a", "b"},
			Outputs:    []string{"y"},
			ParNANDs:   4,
			ParDepth:   3,
			Vectors: []TestVector{
				{In: []bool{false, false}, Out: []bool{false}, Label: "00"},
				{In: []bool{false, true}, Out: []bool{true}, Label: "01"},
				{In: []bool{true, false}, Out: []bool{true}, Label: "10"},
				{In: []bool{true, true}, Out: []bool{false}, Label: "11"},
			},
			StarterNetlist: "in a, b\nout y\nw1 = nand(a, b)\nw2 = nand(a, w1)\nw3 = nand(b, w1)\ny = nand(w2, w3)",
		},
		{
			ID:         "mux2",
			Title:      "2-to-1 Multiplexer",
			Summary:    "Route a when sel=0 and b when sel=1. Optimal design uses 4 NANDs.",
			Difficulty: "Tier 2 · Routing",
			Inputs:     []string{"sel", "a", "b"},
			Outputs:    []string{"y"},
			ParNANDs:   4,
			ParDepth:   3,
			Vectors: []TestVector{
				{In: []bool{false, false, false}, Out: []bool{false}, Label: "s0:0,0"},
				{In: []bool{false, false, true}, Out: []bool{false}, Label: "s0:0,1"},
				{In: []bool{false, true, false}, Out: []bool{true}, Label: "s0:1,0"},
				{In: []bool{false, true, true}, Out: []bool{true}, Label: "s0:1,1"},
				{In: []bool{true, false, false}, Out: []bool{false}, Label: "s1:0,0"},
				{In: []bool{true, false, true}, Out: []bool{true}, Label: "s1:0,1"},
				{In: []bool{true, true, false}, Out: []bool{false}, Label: "s1:1,0"},
				{In: []bool{true, true, true}, Out: []bool{true}, Label: "s1:1,1"},
			},
			StarterNetlist: "in sel, a, b\nout y\nnsel = nand(sel, sel)\nw1 = nand(a, nsel)\nw2 = nand(b, sel)\ny = nand(w1, w2)",
		},
		{
			ID:         "half_adder",
			Title:      "Half Adder",
			Summary:    "Add two 1-bit values into (sum, carry). Composing XOR+AND takes 6 NANDs; sharing nand(a,b) beats it in 5 NANDs.",
			Difficulty: "Tier 3 · Arithmetic",
			Inputs:     []string{"a", "b"},
			Outputs:    []string{"sum", "carry"},
			ParNANDs:   5,
			ParDepth:   3,
			Vectors: []TestVector{
				{In: []bool{false, false}, Out: []bool{false, false}, Label: "0+0"},
				{In: []bool{false, true}, Out: []bool{true, false}, Label: "0+1"},
				{In: []bool{true, false}, Out: []bool{true, false}, Label: "1+0"},
				{In: []bool{true, true}, Out: []bool{false, true}, Label: "1+1"},
			},
			StarterNetlist: "in a, b\nout sum, carry\nsum = chip:xor2_ref(a, b)\ncarry = chip:and2_ref(a, b)",
		},
		{
			ID:         "full_adder",
			Title:      "Full Adder",
			Summary:    "Add a + b + cin into (sum, cout). Composing two half-adders + OR takes 13-15 NANDs; shared NAND logic reaches 9 NANDs.",
			Difficulty: "Tier 3 · Arithmetic",
			Inputs:     []string{"a", "b", "cin"},
			Outputs:    []string{"sum", "cout"},
			ParNANDs:   9,
			ParDepth:   6,
			Vectors: []TestVector{
				{In: []bool{false, false, false}, Out: []bool{false, false}, Label: "0+0+0"},
				{In: []bool{false, false, true}, Out: []bool{true, false}, Label: "0+0+1"},
				{In: []bool{false, true, false}, Out: []bool{true, false}, Label: "0+1+0"},
				{In: []bool{false, true, true}, Out: []bool{false, true}, Label: "0+1+1"},
				{In: []bool{true, false, false}, Out: []bool{true, false}, Label: "1+0+0"},
				{In: []bool{true, false, true}, Out: []bool{false, true}, Label: "1+0+1"},
				{In: []bool{true, true, false}, Out: []bool{false, true}, Label: "1+1+0"},
				{In: []bool{true, true, true}, Out: []bool{true, true}, Label: "1+1+1"},
			},
			StarterNetlist: "in a, b, cin\nout sum, cout\ns1, c1 = chip:half_adder_ref(a, b)\nsum, c2 = chip:half_adder_ref(s1, cin)\ncout = chip:or2_ref(c1, c2)",
		},
		{
			ID:         "adder4",
			Title:      "4-Bit Ripple Carry Adder",
			Summary:    "Compose four full adders to add two 4-bit integers + carry-in across 64 exhaustive & carry-chain test vectors.",
			Difficulty: "Tier 4 · Composite Silicon",
			Inputs:     []string{"a0", "a1", "a2", "a3", "b0", "b1", "b2", "b3", "cin"},
			Outputs:    []string{"s0", "s1", "s2", "s3", "cout"},
			ParNANDs:   36,
			ParDepth:   12,
			Vectors:    buildAdder4Vectors(),
			StarterNetlist: "in a0, a1, a2, a3, b0, b1, b2, b3, cin\n" +
				"out s0, s1, s2, s3, cout\n" +
				"s0, c1 = chip:full_adder_ref(a0, b0, cin)\n" +
				"s1, c2 = chip:full_adder_ref(a1, b1, c1)\n" +
				"s2, c3 = chip:full_adder_ref(a2, b2, c2)\n" +
				"s3, cout = chip:full_adder_ref(a3, b3, c3)",
		},
	}
}

func makeAdder4Vec(a, b, cin int, label string) TestVector {
	sum := a + b + cin
	in := []bool{
		(a & 1) != 0, (a & 2) != 0, (a & 4) != 0, (a & 8) != 0,
		(b & 1) != 0, (b & 2) != 0, (b & 4) != 0, (b & 8) != 0,
		cin != 0,
	}
	out := []bool{
		(sum & 1) != 0, (sum & 2) != 0, (sum & 4) != 0, (sum & 8) != 0,
		(sum & 16) != 0,
	}
	return TestVector{In: in, Out: out, Label: label}
}

func buildAdder4Vectors() []TestVector {
	// 16 hand-picked corner & carry-ripple cases + 48 deterministic spread cases = 64 vectors.
	corners := [][3]int{
		{0, 0, 0},
		{0, 0, 1},
		{15, 0, 1},  // full 4-bit carry ripple
		{0, 15, 1},  // symmetric full carry ripple
		{15, 15, 0}, // max without cin
		{15, 15, 1}, // max with cin
		{5, 10, 0},  // alternating bits 0101 + 1010 = 1111
		{5, 10, 1},  // alternating bits ripple overflow
		{10, 5, 1},
		{8, 8, 0},   // MSB carry out
		{7, 1, 0},   // mid-chain ripple
		{7, 8, 1},
		{1, 14, 1},
		{3, 12, 1},
		{9, 6, 1},
		{12, 7, 0},
	}
	vecs := make([]TestVector, 0, 64)
	seen := make(map[int]bool, 64)
	for i := 0; i < len(corners); i++ {
		a, b, c := corners[i][0], corners[i][1], corners[i][2]
		key := (a << 5) | (b << 1) | c
		seen[key] = true
		vecs = append(vecs, makeAdder4Vec(a, b, c, ufmt.Sprintf("%d+%d+%d", a, b, c)))
	}
	// Deterministic LCG sweep across the remaining 9-bit space.
	state := 137
	for len(vecs) < 64 {
		state = (state*73 + 29) & 511
		if seen[state] {
			continue
		}
		seen[state] = true
		a := (state >> 5) & 15
		b := (state >> 1) & 15
		c := state & 1
		vecs = append(vecs, makeAdder4Vec(a, b, c, ufmt.Sprintf("%d+%d+%d", a, b, c)))
	}
	return vecs
}

// DefaultReferenceChips returns starter verified chips ordered by dependency so
// a freshly deployed realm immediately has a live composable library.
// Deliberately uses composable naive designs for half_adder_ref (6 NANDs),
// full_adder_ref (15 NANDs), and adder4_ref (60 NANDs) so builders can beat
// the records on day one with optimized shared-NAND architectures.
func DefaultReferenceChips() []ReferenceChip {
	return []ReferenceChip{
		{
			ChallengeID: "not1",
			Slug:        "not1_ref",
			Title:       "Reference Inverter",
			Notes:       "Ties both NAND inputs together for a 1-gate NOT.",
			Netlist:     "in a\nout y\ny = nand(a, a)",
		},
		{
			ChallengeID: "and2",
			Slug:        "and2_ref",
			Title:       "Reference AND2",
			Notes:       "NAND followed by chip:not1_ref.",
			Netlist:     "in a, b\nout y\nw = nand(a, b)\ny = chip:not1_ref(w)",
		},
		{
			ChallengeID: "or2",
			Slug:        "or2_ref",
			Title:       "Reference OR2",
			Notes:       "De Morgan OR built by importing chip:not1_ref twice.",
			Netlist:     "in a, b\nout y\nna = chip:not1_ref(a)\nnb = chip:not1_ref(b)\ny = nand(na, nb)",
		},
		{
			ChallengeID: "xor2",
			Slug:        "xor2_ref",
			Title:       "Reference 4-NAND XOR",
			Notes:       "Classic 4-gate balanced NAND XOR.",
			Netlist:     "in a, b\nout y\nw1 = nand(a, b)\nw2 = nand(a, w1)\nw3 = nand(b, w1)\ny = nand(w2, w3)",
		},
		{
			ChallengeID: "mux2",
			Slug:        "mux2_ref",
			Title:       "Reference 2:1 MUX",
			Notes:       "4-NAND multiplexer with inverted select line.",
			Netlist:     "in sel, a, b\nout y\nnsel = chip:not1_ref(sel)\nw1 = nand(a, nsel)\nw2 = nand(b, sel)\ny = nand(w1, w2)",
		},
		{
			ChallengeID: "half_adder",
			Slug:        "half_adder_ref",
			Title:       "Composed Half Adder (6 NAND)",
			Notes:       "Composes chip:xor2_ref + chip:and2_ref (6 NANDs). Beat it in 5 NANDs by sharing nand(a,b).",
			Netlist:     "in a, b\nout sum, carry\nsum = chip:xor2_ref(a, b)\ncarry = chip:and2_ref(a, b)",
		},
		{
			ChallengeID: "full_adder",
			Slug:        "full_adder_ref",
			Title:       "Composed Full Adder (15 NAND)",
			Notes:       "Chains two chip:half_adder_ref + chip:or2_ref. Beat it down to 9 NANDs.",
			Netlist:     "in a, b, cin\nout sum, cout\ns1, c1 = chip:half_adder_ref(a, b)\nsum, c2 = chip:half_adder_ref(s1, cin)\ncout = chip:or2_ref(c1, c2)",
		},
		{
			ChallengeID: "adder4",
			Slug:        "adder4_ref",
			Title:       "4-Bit Ripple Adder (60 NAND)",
			Notes:       "Ripples carry across four imported chip:full_adder_ref blocks. Beat it with optimized sub-chips.",
			Netlist: "in a0, a1, a2, a3, b0, b1, b2, b3, cin\n" +
				"out s0, s1, s2, s3, cout\n" +
				"s0, c1 = chip:full_adder_ref(a0, b0, cin)\n" +
				"s1, c2 = chip:full_adder_ref(a1, b1, c1)\n" +
				"s2, c3 = chip:full_adder_ref(a2, b2, c2)\n" +
				"s3, cout = chip:full_adder_ref(a3, b3, c3)",
		},
	}
}
