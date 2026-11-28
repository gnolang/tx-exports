// Package lru is an Assertpay spec: a fixed-capacity least-recently-used
// cache from string keys to ints.
//
// Every test builds a fresh cache with a capacity, applies a sequence of
// Get and Put calls and compares each answer with a slice model ordered by
// recency. Fixed examples come first; then Cases generated cases from the
// seed, each reproducible with check.Sub(seed, i).
package lru

import "gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/assertpay/check/v1"

// Cache is the interface a solver implements.
type Cache interface {
	// Get returns the value for key and marks key as most recently used.
	Get(key string) (int, bool)
	// Put sets key to v and marks it most recently used. If the cache is
	// full and key is new, the least recently used key is evicted first.
	Put(key string, v int)
	// Len is the number of keys held.
	Len() int
}

// Factory builds an empty cache holding at most capacity keys (>= 1).
type Factory func(capacity int) Cache

const (
	Cases = 16
	Ops   = 14
)

var keys = []string{"a", "b", "c", "d", "e", "f"}

// Spec describes this spec to Assertpay.
func Spec() check.Spec {
	return check.Spec{
		Name:  "lru",
		Doc:   "A fixed-capacity least-recently-used cache: Get refreshes a key, Put inserts or updates and evicts the least recently used key when full. Checked against a slice model.",
		Tests: Tests,
	}
}

type op struct {
	put bool
	key string
	v   int
}

// Tests builds the tests for impl (a Factory or a func(int) Cache).
func Tests(impl any, seed uint64) []check.Test {
	f, ok := asFactory(impl)
	if !ok {
		return []check.Test{{Name: "Type", Fn: func(t *check.T) { t.Fatal("implementation is not an lru.Factory") }}}
	}
	tests := []check.Test{
		{"PutGet", run(f, 2, []op{{true, "a", 1}, {false, "a", 0}})},
		{"Evict", run(f, 2, []op{{true, "a", 1}, {true, "b", 2}, {true, "c", 3}, {false, "a", 0}, {false, "c", 0}})},
		{"Update", run(f, 2, []op{{true, "a", 1}, {true, "a", 5}, {false, "a", 0}})},
		{"Missing", run(f, 1, []op{{false, "z", 0}})},
	}
	for i := 0; i < Cases; i++ {
		r := check.NewRand(check.Sub(seed, i))
		capacity := 1 + r.Intn(4)
		tests = append(tests, check.Test{Name: "Case" + check.Itoa(i), Fn: run(f, capacity, gen(r))})
	}
	return tests
}

func asFactory(impl any) (Factory, bool) {
	switch v := impl.(type) {
	case Factory:
		return v, v != nil
	case func(int) Cache:
		return Factory(v), v != nil
	}
	return nil, false
}

func gen(r *check.Rand) []op {
	ops := make([]op, Ops)
	for i := range ops {
		ops[i] = op{put: r.Intn(2) == 0, key: keys[r.Intn(len(keys))], v: r.Intn(100)}
	}
	return ops
}

func run(f Factory, capacity int, ops []op) func(t *check.T) {
	return func(t *check.T) {
		c := f(capacity)
		var order []string // least recent first
		vals := map[string]int{}
		trace := "cap " + check.Itoa(capacity) + ":"
		for _, o := range ops {
			if o.put {
				trace += " put(" + o.key + "," + check.Itoa(o.v) + ")"
				c.Put(o.key, o.v)
				if _, ok := vals[o.key]; ok {
					order = touch(order, o.key)
				} else {
					if len(order) == capacity {
						delete(vals, order[0])
						order = order[1:]
					}
					order = append(order, o.key)
				}
				vals[o.key] = o.v
			} else {
				trace += " get(" + o.key + ")"
				got, gotOK := c.Get(o.key)
				want, wantOK := vals[o.key]
				if wantOK {
					order = touch(order, o.key)
				}
				if got != want || gotOK != wantOK {
					t.Fatal(trace + " = " + pair(got, gotOK) + ", want " + pair(want, wantOK))
				}
			}
			if c.Len() != len(order) {
				t.Fatal(trace + ": Len() = " + check.Itoa(c.Len()) + ", want " + check.Itoa(len(order)))
			}
		}
	}
}

func touch(order []string, k string) []string {
	out := make([]string, 0, len(order))
	for _, x := range order {
		if x != k {
			out = append(out, x)
		}
	}
	return append(out, k)
}

func pair(v int, ok bool) string {
	if !ok {
		return "(missing)"
	}
	return check.Itoa(v)
}
