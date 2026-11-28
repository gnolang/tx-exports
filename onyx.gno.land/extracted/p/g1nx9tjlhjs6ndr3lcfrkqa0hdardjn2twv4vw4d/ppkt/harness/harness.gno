// Package harness is a tiny test runner that works inside a realm
// transaction: each test runs under recover, so a panicking implementation
// fails one test instead of aborting the transaction.
package harness

// T is passed to each test.
type T struct {
	failed bool
	msg    string
}

type stop struct{}

// Fatal fails the test and stops it.
func (t *T) Fatal(msg string) {
	t.failed = true
	t.msg = msg
	panic(stop{})
}

// Test is one named check. seed varies the inputs per run.
type Test struct {
	Name string
	Fn   func(t *T, seed uint64)
}

// Result of one test.
type Result struct {
	Name string
	Pass bool
	Msg  string
}

// Run runs every test with the seed and returns the results.
func Run(tests []Test, seed uint64) []Result {
	out := make([]Result, 0, len(tests))
	for _, tc := range tests {
		out = append(out, runOne(tc, seed))
	}
	return out
}

func runOne(tc Test, seed uint64) (r Result) {
	r.Name = tc.Name
	t := &T{}
	defer func() {
		if e := recover(); e != nil {
			if _, ok := e.(stop); !ok {
				t.failed = true
				t.msg = "panic"
			}
		}
		r.Pass = !t.failed
		r.Msg = t.msg
	}()
	tc.Fn(t, seed)
	return
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

// Rand is a small deterministic generator (xorshift64).
type Rand struct{ s uint64 }

func NewRand(seed uint64) *Rand {
	if seed == 0 {
		seed = 0x9e3779b97f4a7c15
	}
	return &Rand{seed}
}

func (r *Rand) Next() uint64 {
	r.s ^= r.s << 13
	r.s ^= r.s >> 7
	r.s ^= r.s << 17
	return r.s
}

func (r *Rand) Intn(n int) int { return int(r.Next() % uint64(n)) }
