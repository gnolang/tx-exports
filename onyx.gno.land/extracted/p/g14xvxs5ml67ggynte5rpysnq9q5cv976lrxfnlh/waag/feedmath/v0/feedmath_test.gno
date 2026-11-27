package feedmath

import "testing"

// ---- shared panic helpers ------------------------------------------------
//
// These use plain defer/recover, NOT the test-mode revive() builtin, and the
// distinction matters:
//
//   - revive() exists for panics that cross a REALM boundary, where Go's
//     recover() cannot see them. examples/gno.land/p/nt/grc20/v0/token_test.gno
//     needs it because it wraps every call in cross(...).
//   - feedmath is a pure package that never crosses a boundary, so its panics
//     are ordinary Go panics and recover() catches them - the same pattern as
//     examples/gno.land/r/nt/commondao/v0/reentrancy_test.gno and
//     examples/gno.land/r/nt/grc20reg/v0/grc20reg_test.gno.
//
// (Verified the hard way: an earlier version of these helpers used revive()
// and every panic test failed because revive let the panic through.)
//
// They assert only THAT a panic happened, not its message: the chain wraps
// panic strings, so message equality would be brittle.

// didPanic runs fn and reports whether it panicked.
func didPanic(fn func()) (did bool) {
	defer func() {
		if recover() != nil {
			did = true
		}
	}()
	fn()
	return false
}

func mustPanic(t *testing.T, label string, fn func()) {
	t.Helper()
	if !didPanic(fn) {
		t.Errorf("%s: expected a panic, got none", label)
	}
}

func mustNotPanic(t *testing.T, label string, fn func()) {
	t.Helper()
	if didPanic(fn) {
		t.Errorf("%s: unexpected panic", label)
	}
}

// ---- validation ----------------------------------------------------------

func TestValidPrice(t *testing.T) {
	cases := []struct {
		name string
		p    Price
		want bool
	}{
		{"zero is not a quote", 0, false},
		{"negative", -1, false},
		{"most negative int64", Price(-9223372036854775808), false},
		{"smallest positive", 1, true},
		{"real GNOT quote ($0.049050)", 49050, true},
		{"exactly one dollar", Price(Scale), true},
		{"at the cap", MaxPrice, true},
		{"one above the cap", MaxPrice + 1, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := ValidPrice(c.p); got != c.want {
				t.Errorf("ValidPrice(%d) = %v, want %v", c.p, got, c.want)
			}
		})
	}
}

func TestMustValidPrice(t *testing.T) {
	mustNotPanic(t, "valid mid price", func() { MustValidPrice(49050) })
	mustNotPanic(t, "valid at cap", func() { MustValidPrice(MaxPrice) })
	mustPanic(t, "zero", func() { MustValidPrice(0) })
	mustPanic(t, "negative", func() { MustValidPrice(-5) })
	mustPanic(t, "above cap", func() { MustValidPrice(MaxPrice + 1) })
}

func TestAbsDiff(t *testing.T) {
	cases := []struct {
		name string
		a, b Price
		want Price
	}{
		{"equal", 100, 100, 0},
		{"a above b", 150, 100, 50},
		{"b above a", 100, 150, 50},
		{"adjacent", 101, 100, 1},
		{"widest possible gap", MaxPrice, 1, MaxPrice - 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := AbsDiff(c.a, c.b); got != c.want {
				t.Errorf("AbsDiff(%d, %d) = %d, want %d", c.a, c.b, got, c.want)
			}
		})
	}
	mustPanic(t, "zero operand", func() { AbsDiff(0, 5) })
	mustPanic(t, "over-cap operand", func() { AbsDiff(MaxPrice+1, 5) })
}

// ---- Median3 -------------------------------------------------------------

func TestMedian3(t *testing.T) {
	cases := []struct {
		name    string
		a, b, c Price
		want    Price
	}{
		{"already sorted", 1, 2, 3, 2},
		{"reverse sorted", 3, 2, 1, 2},
		{"median first", 2, 1, 3, 2},
		{"median last", 1, 3, 2, 2},
		{"median in middle slot, high pair", 3, 1, 2, 2},
		{"two low duplicates", 5, 5, 9, 5},
		{"two high duplicates", 5, 9, 9, 9},
		{"all equal", 7, 7, 7, 7},
		{"outlier high cannot move median", 49000, 49100, 999999999, 49100},
		{"outlier low cannot move median", 1, 49000, 49100, 49000},
		{"realistic GNOT spread", 48900, 49050, 49200, 49050},
		{"cap values", MaxPrice, 1, MaxPrice, MaxPrice},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := Median3(tc.a, tc.b, tc.c); got != tc.want {
				t.Errorf("Median3(%d, %d, %d) = %d, want %d", tc.a, tc.b, tc.c, got, tc.want)
			}
		})
	}
}

// TestMedian3AllPermutations is the ordering property for three sources: the
// median must not depend on which source happened to submit first. Submission
// order on-chain is arbitrary, so this is the property that makes the guard and
// the median order-independent (the invariant named in the master doc S9.2).
func TestMedian3AllPermutations(t *testing.T) {
	vals := []Price{48900, 49050, 99200}
	want := Median3(vals[0], vals[1], vals[2])

	orders := [][3]int{
		{0, 1, 2}, {0, 2, 1}, {1, 0, 2},
		{1, 2, 0}, {2, 0, 1}, {2, 1, 0},
	}
	for _, o := range orders {
		got := Median3(vals[o[0]], vals[o[1]], vals[o[2]])
		if got != want {
			t.Errorf("permutation %v gave %d, want %d", o, got, want)
		}
	}
}

func TestMedian3RejectsInvalid(t *testing.T) {
	mustPanic(t, "zero first", func() { Median3(0, 2, 3) })
	mustPanic(t, "zero second", func() { Median3(1, 0, 3) })
	mustPanic(t, "zero third", func() { Median3(1, 2, 0) })
	mustPanic(t, "negative", func() { Median3(1, -2, 3) })
	mustPanic(t, "over cap", func() { Median3(1, 2, MaxPrice+1) })
}

// ---- MedianN -------------------------------------------------------------

func TestMedianN(t *testing.T) {
	cases := []struct {
		name string
		in   []Price
		want Price
	}{
		{"single element", []Price{42}, 42},
		{"two, floor of average", []Price{1, 2}, 1},
		{"two, exact average", []Price{2, 4}, 3},
		{"two equal", []Price{9, 9}, 9},
		{"three unsorted", []Price{3, 1, 2}, 2},
		{"four, floor of middle pair", []Price{1, 2, 3, 4}, 2},
		{"five unsorted", []Price{5, 1, 3, 2, 4}, 3},
		{"duplicates dominate", []Price{9, 9, 9, 1}, 9},
		{"all equal", []Price{5, 5, 5}, 5},
		{"outlier excluded", []Price{49000, 49100, 999999999}, 49100},
		{"at the cap", []Price{MaxPrice, MaxPrice}, MaxPrice},
		{"one below cap pair", []Price{MaxPrice - 1, MaxPrice}, MaxPrice - 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := MedianN(tc.in); got != tc.want {
				t.Errorf("MedianN(%v) = %d, want %d", tc.in, got, tc.want)
			}
		})
	}
}

// TestMedianNDoesNotMutateInput guards the documented promise that a caller's
// slice is copied, not reordered - the realm keeps its submission slices alive
// for rendering after computing a median.
func TestMedianNDoesNotMutateInput(t *testing.T) {
	in := []Price{5, 1, 4, 2, 3}
	before := make([]Price, len(in))
	copy(before, in)

	_ = MedianN(in)

	for i := range in {
		if in[i] != before[i] {
			t.Fatalf("MedianN reordered the caller's slice: got %v, want %v", in, before)
		}
	}
}

func TestMedianNAgreesWithMedian3(t *testing.T) {
	triples := [][3]Price{
		{1, 2, 3}, {3, 2, 1}, {2, 1, 3},
		{5, 5, 9}, {5, 9, 9}, {7, 7, 7},
		{48900, 49050, 49200}, {1, 49000, 49100},
	}
	for _, tr := range triples {
		want := Median3(tr[0], tr[1], tr[2])
		got := MedianN([]Price{tr[0], tr[1], tr[2]})
		if got != want {
			t.Errorf("MedianN(%v) = %d but Median3 = %d", tr, got, want)
		}
	}
}

func TestMedianNRejectsInvalid(t *testing.T) {
	mustPanic(t, "empty slice", func() { MedianN([]Price{}) })
	mustPanic(t, "nil slice", func() { MedianN(nil) })
	mustPanic(t, "contains zero", func() { MedianN([]Price{1, 0, 3}) })
	mustPanic(t, "contains negative", func() { MedianN([]Price{1, -3}) })
	mustPanic(t, "contains over-cap", func() { MedianN([]Price{1, MaxPrice + 1}) })
}
