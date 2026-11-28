package tavernodds

// Tests for the fixed-point LMSR math in lmsr.gno.
//
// Expected values are taken from lmsr_reference.py (plain f64 port of
// the Rust Prophet math), rounded to the nearest integer. Gno results
// must agree within the stated tolerances — the Python is never
// adjusted to match the Gno code.
//
// Tolerances (measured maxima over a 716-cost / 860-delta / 716-price
// sweep, incl. q up to LMSRMaxQ, are ~4x inside these bounds):
//   - cost / cost-delta: max(10 ugnot, b*2e-8)  [worst observed 49 ugnot at b=1e10]
//   - price: 1 bp (worst observed 0 bps over 716 cases)
//   - exp/ln primitives: 10 units at 1e9 scale (worst observed ~3)
//   - min seed: true ceil <= got <= ceil+6 (worst observed +5)

import "testing"

// costTol is the allowed |gno - f64| for a cost/delta at liquidity b.
func costTol(b int64) int64 {
	tol := b / 50000000 // b*2e-8
	if tol < 10 {
		tol = 10
	}
	return tol
}

func abs64(x int64) int64 {
	if x < 0 {
		return -x
	}
	return x
}

func TestLMSRCost(t *testing.T) {
	cases := []struct {
		qy, qn, b int64
		want      int64 // f64 reference, rounded
	}{
		{0, 0, 100000000, 69314718},              // b*ln2
		{0, 0, 1000000, 693147},                  // b*ln2, min b
		{0, 0, 10000000000, 6931471806},          // b*ln2, max b
		{1000000000, 1000000000, 100000000, 1069314718},
		{10000000, 10000000, 100000000, 79314718},
		{100000000, 0, 100000000, 131326169}, // one-sided YES
		{0, 100000000, 100000000, 131326169}, // one-sided NO (symmetric)
		{50000000, 30000000, 100000000, 109813887},
		{30000000, 50000000, 100000000, 109813887},
		{1000000000, 0, 100000000, 1000004540},
		{1000000000, 500000000, 100000000, 1000671535},
		{10000000, 0, 100000000, 74439666},
		{5000000, 2000000, 1000000, 5048587},
		{50000000000, 30000000000, 10000000000, 51269280110},
		{1000000000000, 1000000000, 100000000, 1000000000000}, // exp(-9990) -> 0
		{1000000000000, 1000000000000, 1000000, 1000000693147},
	}
	for _, c := range cases {
		got := lmsrCost(c.qy, c.qn, c.b)
		if d := abs64(got - c.want); d > costTol(c.b) {
			t.Errorf("lmsrCost(%d,%d,%d) = %d, want %d (err %d > tol %d)",
				c.qy, c.qn, c.b, got, c.want, d, costTol(c.b))
		}
	}
}

func TestLMSRCostDelta(t *testing.T) {
	cases := []struct {
		qy, qn, b, dy, dn int64
		want              int64 // f64 reference, rounded
	}{
		{0, 0, 100000000, 10000000, 0, 5124948},       // buy YES from zero
		{0, 0, 100000000, 0, 10000000, 5124948},      // buy NO from zero
		{100000000, 0, 100000000, 10000000, 0, 7407364}, // buy YES when dear
		{0, 0, 100000000, 1, 0, 1},                   // 1-share buy, true 0.5
		{0, 0, 100000000, 1000, 0, 500},              // true 500.001
		{10000000, 0, 100000000, -10000000, 0, -5124948}, // sell all YES
		{50000000, 30000000, 100000000, 0, -5000000, -2219945},
		{0, 0, 100000000, 10000000, 10000000, 10000000}, // buy both = shares
		{0, 0, 1000000, 100000, 0, 51249},            // small b
		{0, 0, 100000000, 500000000, 0, 431356817},    // large buy
	}
	for _, c := range cases {
		got := lmsrCostDelta(c.qy, c.qn, c.b, c.dy, c.dn)
		if d := abs64(got - c.want); d > costTol(c.b) {
			t.Errorf("lmsrCostDelta(%d,%d,%d,%d,%d) = %d, want %d (err %d > tol %d)",
				c.qy, c.qn, c.b, c.dy, c.dn, got, c.want, d, costTol(c.b))
		}
	}
	// Sell is the exact negative of the corresponding buy.
	buy := lmsrCostDelta(0, 0, 100000000, 10000000, 0)
	sell := lmsrCostDelta(10000000, 0, 100000000, -10000000, 0)
	if buy+sell != 0 {
		t.Errorf("buy+sell roundtrip = %d, want 0 (buy %d, sell %d)", buy+sell, buy, sell)
	}
	// Buying YES when YES is already expensive costs more per share.
	cheap := lmsrCostDelta(0, 0, 100000000, 10000000, 0)
	dear := lmsrCostDelta(100000000, 0, 100000000, 10000000, 0)
	if !(dear > cheap) {
		t.Errorf("dear buy %d should exceed cheap buy %d", dear, cheap)
	}
	// Selling more than held clamps to selling everything held.
	over := lmsrCostDelta(100, 0, 100000000, -200, 0)
	all := lmsrCostDelta(100, 0, 100000000, -100, 0)
	if over != all {
		t.Errorf("oversell %d should equal sell-all %d", over, all)
	}
}

func TestLMSRPriceBps(t *testing.T) {
	cases := []struct {
		qy, qn, b int64
		wantYes   int64
	}{
		{0, 0, 100000000, 5000},
		{10000000, 0, 100000000, 5250},
		{20000000, 0, 100000000, 5498},
		{50000000, 0, 100000000, 6225},
		{100000000, 0, 100000000, 7311},
		{500000000, 0, 100000000, 9933},
		{0, 100000000, 100000000, 2689},
		{50000000, 30000000, 100000000, 5498},
		{30000000, 50000000, 100000000, 4502},
		{1000000000, 0, 100000000, 10000}, // extreme YES
		{0, 1000000000, 100000000, 0},     // extreme NO
		{50000000, 0, 1000000, 10000},     // extreme at min b
		{0, 50000000, 1000000, 0},
		{1000001, 1000000, 100000000, 5000}, // 1-ugnot difference: still 50/50
		{1000000000, 1000000000, 100000000, 5000},
		{5000000000, 0, 10000000000, 6225},
	}
	for _, c := range cases {
		gotYes := lmsrPriceBps(c.qy, c.qn, c.b, true)
		gotNo := lmsrPriceBps(c.qy, c.qn, c.b, false)
		if d := abs64(gotYes - c.wantYes); d > 1 {
			t.Errorf("lmsrPriceBps(%d,%d,%d,YES) = %d, want %d",
				c.qy, c.qn, c.b, gotYes, c.wantYes)
		}
		if gotYes+gotNo != 10000 {
			t.Errorf("prices sum %d + %d != 10000 at (%d,%d,%d)",
				gotYes, gotNo, c.qy, c.qn, c.b)
		}
	}
	// Monotone in qYes: price never decreases as YES shares grow.
	prev := int64(-1)
	for _, q := range []int64{0, 10000000, 20000000, 50000000, 100000000, 500000000} {
		p := lmsrPriceBps(q, 0, 100000000, true)
		if p < prev {
			t.Errorf("price not monotone: %d after %d at q=%d", p, prev, q)
		}
		prev = p
	}
	if prev <= 9000 {
		t.Errorf("deep YES price %d should exceed 9000", prev)
	}
}

func TestLMSRMonotoneAndSolvent(t *testing.T) {
	b := int64(100000000)
	// Cost increases with either side's shares.
	states := [][2]int64{
		{0, 0}, {10000000, 0}, {0, 10000000}, {50000000, 30000000},
		{1000000000, 1000000000}, {1000000000, 0}, {1000000000000, 1000000000},
	}
	for _, s := range states {
		c := lmsrCost(s[0], s[1], b)
		// Solvency: C(q) >= max(qy, qn), up to the fixed-point tolerance.
		mx := s[0]
		if s[1] > mx {
			mx = s[1]
		}
		if c+costTol(b) < mx {
			t.Errorf("C(%d,%d) = %d < max q %d", s[0], s[1], c, mx)
		}
	}
	// Strictly increasing along the YES axis.
	prev := lmsrCost(0, 0, b)
	for _, q := range []int64{1, 1000, 10000000, 100000000, 1000000000} {
		c := lmsrCost(q, 0, b)
		if c <= prev {
			t.Errorf("cost not increasing: C(%d,0)=%d <= C(prev)=%d", q, c, prev)
		}
		prev = c
	}
}

func TestLMSRMinSeed(t *testing.T) {
	// want = ceil(b*ln2) from the f64 reference.
	cases := []struct {
		b    int64
		want int64
	}{
		{1000000, 693148},
		{100000000, 69314719},
		{10000000000, 6931471806},
	}
	for _, c := range cases {
		got := lmsrMinSeed(c.b)
		if got < c.want || got-c.want > 6 {
			t.Errorf("lmsrMinSeed(%d) = %d, want ceil %d (+0..6)", c.b, got, c.want)
		}
	}
	if got := lmsrMinSeed(0); got != 0 {
		t.Errorf("lmsrMinSeed(0) = %d, want 0", got)
	}
}

func TestLMSRInvalidInputs(t *testing.T) {
	// Out-of-domain inputs return 0 instead of overflowing/panicking.
	if got := lmsrCost(0, 0, 0); got != 0 {
		t.Errorf("lmsrCost b=0 = %d, want 0", got)
	}
	if got := lmsrCost(0, 0, 999999); got != 0 {
		t.Errorf("lmsrCost b<MIN = %d, want 0", got)
	}
	if got := lmsrCost(0, 0, 10000000001); got != 0 {
		t.Errorf("lmsrCost b>MAX = %d, want 0", got)
	}
	if got := lmsrCost(-1, 0, 100000000); got != 0 {
		t.Errorf("lmsrCost q<0 = %d, want 0", got)
	}
	if got := lmsrCost(1000000000001, 0, 100000000); got != 0 {
		t.Errorf("lmsrCost q>MAX = %d, want 0", got)
	}
	if got := lmsrPriceBps(0, 0, 0, true); got != 0 {
		t.Errorf("lmsrPriceBps b=0 = %d, want 0", got)
	}
	if got := lmsrCostDelta(0, 0, 100000000, 1000000000001, 0); got != 0 {
		t.Errorf("lmsrCostDelta d>MAX = %d, want 0", got)
	}
	if got := lmsrCostDelta(0, 0, 100000000, 0, 0); got != 0 {
		t.Errorf("lmsrCostDelta zero trade = %d, want 0", got)
	}
}

func TestLMSRExpLnPrimitives(t *testing.T) {
	// exp(0) = 1 and exp(-50) ~ 0 are exact by construction.
	if got := expNeg(0); got != 1000000000 {
		t.Errorf("expNeg(0) = %d, want 1000000000", got)
	}
	if got := expNeg(-50000000000); got != 0 {
		t.Errorf("expNeg(-50) = %d, want 0", got)
	}
	// exp(-ln2) = 0.5 exactly (up to primitive tolerance).
	if got := expNeg(-693147181); abs64(got-500000000) > 10 {
		t.Errorf("expNeg(-ln2) = %d, want 500000000", got)
	}
	// exp(-10 ln2) = 1/1024 = 976562.5 (scaled).
	if got := expNeg(-6931471810); abs64(got-976563) > 10 {
		t.Errorf("expNeg(-10 ln2) = %d, want 976563", got)
	}
	// ln(1) = 0 exactly; ln(2) and ln(1.5) from f64.
	if got := ln1to2(1000000000); got != 0 {
		t.Errorf("ln1to2(1) = %d, want 0", got)
	}
	if got := ln1to2(2000000000); abs64(got-693147181) > 10 {
		t.Errorf("ln1to2(2) = %d, want 693147181", got)
	}
	if got := ln1to2(1500000000); abs64(got-405465108) > 10 {
		t.Errorf("ln1to2(1.5) = %d, want 405465108", got)
	}
}

func TestMulDivSanity(t *testing.T) {
	if got := mulDiv(7, 3, 2); got != 10 {
		t.Errorf("mulDiv(7,3,2) = %d, want 10", got)
	}
	if got := mulDiv(1000000000000, 1000000000, 100000000); got != 10000000000000 {
		t.Errorf("mulDiv(1e12,1e9,1e8) = %d, want 1e13", got)
	}
	// (1e15 * 1e10) / 1e9 = 1e16 — the largest product this helper is used for.
	if got := mulDiv(1000000000000000, 10000000000, 1000000000); got != 10000000000000000 {
		t.Errorf("mulDiv(1e15,1e10,1e9) = %d, want 1e16", got)
	}
}
