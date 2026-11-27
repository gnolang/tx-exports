// Pure-math unit tests for the demo vault's valuation helpers. No heights,
// no oracle state - every expected value below was recomputed offline with
// independent integer arithmetic (§0.1 cross-check rule).
package demo

import (
	"testing"

	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
)

func TestPnlBps(cur realm, t *testing.T) {
	cases := []struct {
		entry, current feedmath.Price
		want           int64
	}{
		{45050, 45050, 0},                        // flat
		{45050, 49555, 1000},                     // +10% exactly: 4505*1e4/45050
		{45050, 40520, -1005},                    // 4530*1e4/45050 = 1005.5 -> truncated 1005
		{45050, 37125, -1759},                    // the crash-ladder endpoint
		{100, 99, -100},                          // small numbers stay exact
		{1000000, 1, -9999},                      // (1e6-1)*1e4/1e6 = 9999.99 -> 9999
		{1, 100000000000000, 999999999999990000}, // overflow headroom: (1e14-1)*1e4 ~ 1e18
	}
	for _, c := range cases {
		if got := pnlBps(c.entry, c.current); got != c.want {
			t.Errorf("pnlBps(%d, %d) = %d, want %d", c.entry, c.current, got, c.want)
		}
	}
}

func TestValueMicroUSD(cur realm, t *testing.T) {
	// 500 GNOT (500e6 ugnot) at $0.045050 = $22.525 = 22,525,000 micro-USD.
	if v, ok := valueMicroUSD(500000000, 45050); !ok || v != 22525000 {
		t.Errorf("valueMicroUSD(500e6, 45050) = %d, %v; want 22525000, true", v, ok)
	}
	// Smallest meaningful unit: 1 ugnot at $1.00 -> 1 micro-USD.
	if v, ok := valueMicroUSD(1, 1000000); !ok || v != 1 {
		t.Errorf("valueMicroUSD(1, 1e6) = %d, %v; want 1, true", v, ok)
	}
	// Zero inputs are not valuations.
	if _, ok := valueMicroUSD(0, 45050); ok {
		t.Error("zero amount must not value")
	}
	if _, ok := valueMicroUSD(500, 0); ok {
		t.Error("zero price must not value")
	}
	// The overflow guard: 1e9 ugnot at MaxPrice (1e14) is a 1e23 product -
	// far past int64 - so it must report "does not fit", not wrap negative.
	if _, ok := valueMicroUSD(1000000000, feedmath.MaxPrice); ok {
		t.Error("1e9 ugnot at MaxPrice must trip the overflow guard")
	}
	// Just under the guard: 1 ugnot at MaxPrice = 1e14/1e6 = 1e8 micro-USD.
	if v, ok := valueMicroUSD(1, feedmath.MaxPrice); !ok || v != 100000000 {
		t.Errorf("valueMicroUSD(1, MaxPrice) = %d, %v; want 100000000, true", v, ok)
	}
}

func TestHealthPct(cur realm, t *testing.T) {
	cases := []struct {
		entry, current feedmath.Price
		want           int64
	}{
		{45050, 45050, 100}, // flat
		{45050, 37125, 82},  // 3712500/45050 = 82.4 -> 82
		{45050, 90100, 200}, // doubled
		{45050, 40520, 89},  // 4052000/45050 = 89.9 -> 89
	}
	for _, c := range cases {
		if got := healthPct(c.entry, c.current); got != c.want {
			t.Errorf("healthPct(%d, %d) = %d, want %d", c.entry, c.current, got, c.want)
		}
	}
}

func TestIsUnderwater(cur realm, t *testing.T) {
	thresholdBps = DefaultThresholdBps // defensive: pure tests own this var here
	defer func() { thresholdBps = DefaultThresholdBps }()

	// -1005 bps breaches the default 1000 bps threshold.
	if !isUnderwater(45050, 40520) {
		t.Error("a -1005 bps move must be underwater at threshold 1000")
	}
	// -999 bps does not (4504*1e4/45050 = 999.7 -> 999).
	if isUnderwater(45050, 40546) {
		t.Error("a -999 bps move must not be underwater at threshold 1000")
	}
	// The boundary is inclusive: exactly -1000 counts as underwater, matching
	// the deviation guard's "reject only strictly greater" convention.
	if !isUnderwater(10000, 9000) {
		t.Error("exactly -1000 bps must be underwater at threshold 1000")
	}
	// No move is never underwater at the default threshold...
	if isUnderwater(45050, 45050) {
		t.Error("a flat position must not be underwater at threshold 1000")
	}
	// ...but a 0 bps threshold flags any dip at all, and even flat (<= -0).
	thresholdBps = 0
	if !isUnderwater(45050, 45050) {
		t.Error("threshold 0 must flag a flat position (pnl 0 <= -0)")
	}
	// A wider threshold unflags the -1005 move.
	thresholdBps = 2000
	if isUnderwater(45050, 40520) {
		t.Error("a -1005 bps move must not be underwater at threshold 2000")
	}
}

func TestParseFreshCount(cur realm, t *testing.T) {
	// The real header the oracle emits (oracle.gno GetSources).
	full := "asset=GNOT fresh=2/3 quorum=2\n" +
		"kucoin price=$0.045000 age=0 status=FRESH rejected=0"
	if n, ok := parseFreshCount(full); !ok || n != 2 {
		t.Errorf("parseFreshCount(real snapshot) = %d, %v; want 2, true", n, ok)
	}
	if n, ok := parseFreshCount("asset=GNOT fresh=0/3 quorum=2"); !ok || n != 0 {
		t.Errorf("fresh=0 must parse as 0/true, got %d, %v", n, ok)
	}

	bad := []string{
		"",                    // nothing at all
		"freshx=2/3",          // near-miss key must not match
		"fresh=abc/3",         // non-numeric
		"fresh=2",             // missing the /M part
		"fresh=/3",            // empty numerator
		"fresh=-1/3",          // negative count is nonsense
		"asset=GNOT quorum=2", // header without fresh=
	}
	for _, s := range bad {
		if n, ok := parseFreshCount(s); ok {
			t.Errorf("parseFreshCount(%q) = %d, true; want false", s, n)
		}
	}
}
