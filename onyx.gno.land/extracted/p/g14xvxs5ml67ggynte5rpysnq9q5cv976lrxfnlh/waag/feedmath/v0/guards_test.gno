package feedmath

import "testing"

// The arithmetic behind every expected value below is written out, because the
// whole point of these tests is to be an independent check on the code rather
// than a restatement of it. DeviationOK compares:
//
//	diff * BpsScale <= thresholdBps * reference
//
// so with reference = 1000000 ($1.00) and a 1000 bps (10%) threshold the
// allowance is 1000 * 1000000 / 10000 = 100000 units, i.e. exactly $0.10.

func TestDeviationOK(t *testing.T) {
	const ref = Price(1000000) // $1.00

	cases := []struct {
		name      string
		candidate Price
		reference Price
		bps       int64
		want      bool
	}{
		// ---- 10% guard, the shipped default ----
		{"identical", ref, ref, 1000, true},
		{"exactly +10% (boundary, accepted)", 1100000, ref, 1000, true},
		{"one unit over +10% (rejected)", 1100001, ref, 1000, false},
		{"exactly -10% (boundary, accepted)", 900000, ref, 1000, true},
		{"one unit under -10% (rejected)", 899999, ref, 1000, false},
		{"well inside", 1050000, ref, 1000, true},
		{"way outside", 2000000, ref, 1000, false},

		// ---- other thresholds ----
		{"zero bps, identical", ref, ref, 0, true},
		{"zero bps, off by one", ref + 1, ref, 0, false},
		{"one bp, inside", ref + 99, ref, 1, true}, // 99*10000 < 1*1000000
		{"one bp, exactly at limit", ref + 100, ref, 1, true},
		{"one bp, over", ref + 101, ref, 1, false}, // 101*10000 > 1*1000000
		{"100% guard accepts double", ref * 2, ref, 10000, true},
		{"100% guard accepts zero-ish low", 1, ref, 10000, true},

		// ---- realistic GNOT numbers ($0.0489 - $0.0492) ----
		{"honest kucoin vs kraken", 48900, 49050, 1000, true},   // 30 bps apart
		{"honest spread wide side", 49200, 49050, 1000, true},   // 30 bps apart
		{"poisoned source rejected", 99200, 49050, 1000, false}, // ~102% off
		{"poisoned low rejected", 4000, 49050, 1000, false},     // ~92% off
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := DeviationOK(tc.candidate, tc.reference, tc.bps); got != tc.want {
				t.Errorf("DeviationOK(%d, %d, %d) = %v, want %v",
					tc.candidate, tc.reference, tc.bps, got, tc.want)
			}
		})
	}
}

// TestDeviationOKIsSymmetric: the guard must behave the same whether the
// candidate sits above or below the reference by the same amount. A one-sided
// guard would let cheap manipulation through in one direction only.
func TestDeviationOKIsSymmetric(t *testing.T) {
	const ref = Price(1000000)
	for _, delta := range []int64{1, 100, 99999, 100000, 100001, 500000} {
		up := DeviationOK(ref+Price(delta), ref, 1000)
		down := DeviationOK(ref-Price(delta), ref, 1000)
		if up != down {
			t.Errorf("asymmetric at delta %d: above=%v below=%v", delta, up, down)
		}
	}
}

func TestDeviationOKRejectsInvalidInput(t *testing.T) {
	const ref = Price(1000000)
	mustPanic(t, "zero candidate", func() { DeviationOK(0, ref, 1000) })
	mustPanic(t, "zero reference", func() { DeviationOK(ref, 0, 1000) })
	mustPanic(t, "negative candidate", func() { DeviationOK(-1, ref, 1000) })
	mustPanic(t, "over-cap candidate", func() { DeviationOK(MaxPrice+1, ref, 1000) })
	mustPanic(t, "negative threshold", func() { DeviationOK(ref, ref, -1) })
	mustPanic(t, "threshold over 100%", func() { DeviationOK(ref, ref, 10001) })
	mustNotPanic(t, "threshold at 100%", func() { DeviationOK(ref, ref, 10000) })
	mustNotPanic(t, "threshold zero", func() { DeviationOK(ref, ref, 0) })
}

func TestDeviationBps(t *testing.T) {
	const ref = Price(1000000)
	cases := []struct {
		name      string
		candidate Price
		reference Price
		want      int64
	}{
		{"identical", ref, ref, 0},
		{"exactly 10%", 1100000, ref, 1000},
		{"exactly 10% below", 900000, ref, 1000},
		{"one unit over truncates down", 1100001, ref, 1000}, // 1000.01 -> 1000
		{"one bp", ref + 100, ref, 1},
		{"sub-bp deviation truncates to zero", ref + 99, ref, 0},
		{"realistic GNOT 30 bps", 48900, 49050, 30},
		{"poisoned source over 100%", 99200, 49050, 10224},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := DeviationBps(tc.candidate, tc.reference); got != tc.want {
				t.Errorf("DeviationBps(%d, %d) = %d, want %d",
					tc.candidate, tc.reference, got, tc.want)
			}
		})
	}
}

// TestDeviationBpsAgreesWithGuard: the number we show a human in a rejection
// reason must not contradict the decision the guard actually made.
//
// The two directions are NOT symmetric, and the asymmetry is real rather than
// sloppy:
//
//   - accepted  =>  reported bps <= limit   (always: the guard's exact product
//     test is at least as strict as the truncated report)
//   - rejected  =>  reported bps >= limit   (NOT "> limit": DeviationBps floors,
//     so a price rejected by a hair still reports exactly the limit - e.g.
//     against a 49050 reference, 53956 is rejected yet reads as 1000 bps)
//
// Asserting "> limit" on the reject side would be asserting something false
// about our own arithmetic, so it is not asserted.
func TestDeviationBpsAgreesWithGuard(t *testing.T) {
	const ref = Price(49050)
	const bps = int64(1000)
	for _, cand := range []Price{48000, 48600, 48900, 49050, 49200, 49540, 49541, 53955, 53956, 99200} {
		ok := DeviationOK(cand, ref, bps)
		got := DeviationBps(cand, ref)
		if ok && got > bps {
			t.Errorf("accepted %d but reported %d bps > limit %d", cand, got, bps)
		}
		if !ok && got < bps {
			t.Errorf("rejected %d but reported only %d bps < limit %d", cand, got, bps)
		}
	}
}

// ---- staleness -----------------------------------------------------------

func TestIsFresh(t *testing.T) {
	const now = int64(1390523) // a real Onyx height from the M1 deploy

	cases := []struct {
		name      string
		submitted int64
		current   int64
		window    int64
		want      bool
	}{
		{"same block", now, now, 300, true},
		{"one block old", now - 1, now, 300, true},
		{"exactly at window (boundary, fresh)", now - 300, now, 300, true},
		{"one past window (stale)", now - 301, now, 300, false},
		{"very old", now - 1000000, now, 300, false},
		{"zero window, same block", now, now, 0, true},
		{"zero window, one block old", now - 1, now, 0, false},
		{"genesis submission", 0, now, 300, false},
		{"FUTURE dated is never fresh", now + 1, now, 300, false},
		{"FAR future dated is never fresh", now + 99999999, now, 300, false},
		{"chain at height zero", 0, 0, 300, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := IsFresh(tc.submitted, tc.current, tc.window)
			if got != tc.want {
				t.Errorf("IsFresh(%d, %d, %d) = %v, want %v",
					tc.submitted, tc.current, tc.window, got, tc.want)
			}
		})
	}
}

func TestIsFreshRejectsNegativeWindow(t *testing.T) {
	mustPanic(t, "window -1", func() { IsFresh(10, 20, -1) })
	mustNotPanic(t, "window 0", func() { IsFresh(10, 20, 0) })
}

func TestBlockAge(t *testing.T) {
	cases := []struct {
		name      string
		submitted int64
		current   int64
		want      int64
	}{
		{"same block", 100, 100, 0},
		{"normal age", 100, 400, 300},
		{"future clamps to zero (display only)", 500, 100, 0},
		{"far future clamps to zero", 99999999, 100, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := BlockAge(tc.submitted, tc.current); got != tc.want {
				t.Errorf("BlockAge(%d, %d) = %d, want %d",
					tc.submitted, tc.current, got, tc.want)
			}
		})
	}
}
