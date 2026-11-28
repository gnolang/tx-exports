// Package intervals is an Assertpay spec: a set of integers stored as
// half-open intervals.
//
// An implementation provides a Factory. Every test builds a fresh Set,
// applies a sequence of operations and compares the result with a simple
// bitmap model. Fixed examples come first; then Cases generated cases from
// the seed, each reproducible on its own with check.Sub(seed, i).
package intervals

import (
	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/aprh2/check/v1"
)

// Set is the interface a solver implements.
type Set interface {
	// Add inserts every x with lo <= x < hi. lo >= hi is a no-op.
	Add(lo, hi int)
	// Remove deletes every x with lo <= x < hi. lo >= hi is a no-op.
	Remove(lo, hi int)
	// Contains reports whether x is in the set.
	Contains(x int) bool
	// Spans returns the set as sorted, disjoint, non-touching half-open
	// intervals: [lo, hi) pairs where each hi < the next lo.
	Spans() [][2]int
}

// Factory builds an empty Set.
type Factory func() Set

const (
	// Cases is the number of generated cases per seed.
	Cases = 16
	// Universe bounds generated values to [0, Universe).
	Universe = 48
	// Ops is the number of operations per generated case.
	Ops = 12
)

// Spec describes this spec to Assertpay.
func Spec() check.Spec {
	return check.Spec{
		Name:  "intervals",
		Doc:   "An integer set stored as half-open intervals: Add, Remove, Contains and Spans (sorted, disjoint, merged). Checked against a bitmap model.",
		Tests: Tests,
	}
}

type op struct {
	add    bool
	lo, hi int
}

// Tests builds the tests for impl (a Factory or a func() Set).
func Tests(impl any, seed uint64) []check.Test {
	f, ok := asFactory(impl)
	if !ok {
		return []check.Test{{Name: "Type", Fn: func(t *check.T) { t.Fatal("implementation is not an intervals.Factory") }}}
	}
	tests := []check.Test{
		{"AddOne", run(f, []op{{true, 2, 5}})},
		{"MergeOverlap", run(f, []op{{true, 1, 4}, {true, 3, 8}})},
		{"RemoveMiddle", run(f, []op{{true, 0, 10}, {false, 4, 6}})},
		{"EmptyRange", run(f, []op{{true, 5, 5}, {true, 7, 3}})},
	}
	for i := 0; i < Cases; i++ {
		tests = append(tests, check.Test{Name: "Case" + check.Itoa(i), Fn: run(f, gen(check.Sub(seed, i)))})
	}
	return tests
}

func asFactory(impl any) (Factory, bool) {
	switch v := impl.(type) {
	case Factory:
		return v, v != nil
	case func() Set:
		return Factory(v), v != nil
	}
	return nil, false
}

func gen(seed uint64) []op {
	r := check.NewRand(seed)
	ops := make([]op, Ops)
	for i := range ops {
		lo := r.Intn(Universe)
		ops[i] = op{add: r.Intn(3) != 0, lo: lo, hi: lo + 1 + r.Intn(8)}
	}
	return ops
}

// run applies ops to a fresh Set and to the model, then compares.
func run(f Factory, ops []op) func(t *check.T) {
	return func(t *check.T) {
		s := f()
		var model [Universe + 16]bool
		for _, o := range ops {
			if o.add {
				s.Add(o.lo, o.hi)
			} else {
				s.Remove(o.lo, o.hi)
			}
			for x := o.lo; x < o.hi && x < len(model); x++ {
				model[x] = o.add
			}
		}
		for x := 0; x < len(model); x++ {
			if s.Contains(x) != model[x] {
				t.Fatal("after " + describe(ops) + ": Contains(" + check.Itoa(x) + ") = " + boolText(!model[x]))
			}
		}
		want := spansOf(model[:])
		got := s.Spans()
		if !equal(got, want) {
			t.Fatal("after " + describe(ops) + ": Spans() = " + spansText(got) + ", want " + spansText(want))
		}
	}
}

func spansOf(m []bool) [][2]int {
	var out [][2]int
	for x := 0; x < len(m); x++ {
		if m[x] && (x == 0 || !m[x-1]) {
			out = append(out, [2]int{x, x})
		}
		if m[x] && (x == len(m)-1 || !m[x+1]) {
			out[len(out)-1][1] = x + 1
		}
	}
	return out
}

func equal(a, b [][2]int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func describe(ops []op) string {
	s := ""
	for i, o := range ops {
		if i > 0 {
			s += " "
		}
		if o.add {
			s += "+"
		} else {
			s += "-"
		}
		s += "[" + check.Itoa(o.lo) + "," + check.Itoa(o.hi) + ")"
	}
	return s
}

func spansText(sp [][2]int) string {
	s := "{"
	for i, p := range sp {
		if i > 0 {
			s += " "
		}
		s += "[" + check.Itoa(p[0]) + "," + check.Itoa(p[1]) + ")"
	}
	return s + "}"
}

func boolText(b bool) string {
	if b {
		return "true"
	}
	return "false"
}
