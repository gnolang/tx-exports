// Package check is a small test harness that runs inside a transaction.
//
// Go's testing package only runs under `gno test`. Assertpay needs the
// same idea on chain: a spec's tests run against a submitted implementation
// while a realm call is executing, and every result is kept. Each test runs
// under recover, so a panic in the implementation (declared in a /p/
// package) fails that one test instead of aborting the transaction.
package check

import "strconv"

// T is handed to each test.
type T struct {
	failed bool
	msg    string
}

type stop struct{}

// Fatal fails the test with msg and stops it.
func (t *T) Fatal(msg string) {
	t.failed = true
	t.msg = msg
	panic(stop{})
}

// Check fails the test with msg if ok is false.
func (t *T) Check(ok bool, msg string) {
	if !ok {
		t.Fatal(msg)
	}
}

// Test is one named check.
type Test struct {
	Name string
	Fn   func(t *T)
}

// Result is the outcome of one test.
type Result struct {
	Name string
	Pass bool
	Msg  string
}

// Spec describes a spec package to the Assertpay realm.
type Spec struct {
	Name string // short id, e.g. "intervals"
	Doc  string // one paragraph for humans
	// Tests builds the tests for an implementation and a seed. impl is
	// whatever the solver submitted; a spec must turn a wrong type into a
	// failing test, never a panic.
	Tests func(impl any, seed uint64) []Test
}

// Run runs every test and returns the results in order.
func Run(tests []Test) []Result {
	out := make([]Result, 0, len(tests))
	for _, tc := range tests {
		out = append(out, runOne(tc))
	}
	return out
}

// RunSpec builds and runs a spec's tests for impl and seed.
func RunSpec(s Spec, impl any, seed uint64) []Result {
	var tests []Test
	func() {
		defer func() {
			if recover() != nil {
				tests = []Test{{Name: "Build", Fn: func(t *T) { t.Fatal("the spec could not build tests for this implementation") }}}
			}
		}()
		tests = s.Tests(impl, seed)
	}()
	return Run(tests)
}

func runOne(tc Test) (r Result) {
	r.Name = tc.Name
	t := &T{}
	defer func() {
		if e := recover(); e != nil {
			if _, ok := e.(stop); !ok {
				t.failed = true
				t.msg = "implementation panicked: " + panicText(e)
			}
		}
		r.Pass = !t.failed
		r.Msg = t.msg
	}()
	tc.Fn(t)
	return
}

func panicText(e any) string {
	switch v := e.(type) {
	case string:
		return v
	case error:
		return v.Error()
	}
	return "non-string panic"
}

// Passed counts passing results.
func Passed(rs []Result) int {
	n := 0
	for _, r := range rs {
		if r.Pass {
			n++
		}
	}
	return n
}

// FirstFailure returns the first failing result, if any.
func FirstFailure(rs []Result) (Result, bool) {
	for _, r := range rs {
		if !r.Pass {
			return r, true
		}
	}
	return Result{}, false
}

// Rand is a small deterministic generator (xorshift64*).
type Rand struct{ s uint64 }

// NewRand returns a generator for seed (0 is remapped).
func NewRand(seed uint64) *Rand {
	if seed == 0 {
		seed = 0x9e3779b97f4a7c15
	}
	return &Rand{s: seed}
}

// Next returns the next 64-bit value.
func (r *Rand) Next() uint64 {
	r.s ^= r.s >> 12
	r.s ^= r.s << 25
	r.s ^= r.s >> 27
	return r.s * 2685821657736338717
}

// Intn returns a value in [0, n).
func (r *Rand) Intn(n int) int {
	if n <= 0 {
		return 0
	}
	return int(r.Next() % uint64(n))
}

// Sub derives an independent seed for case i, so each generated case can be
// reproduced on its own.
func Sub(seed uint64, i int) uint64 {
	r := NewRand(seed ^ (uint64(i+1) * 0x9e3779b97f4a7c15))
	r.Next()
	return r.Next()
}

// Itoa is strconv.Itoa, re-exported for spec messages.
func Itoa(n int) string { return strconv.Itoa(n) }
