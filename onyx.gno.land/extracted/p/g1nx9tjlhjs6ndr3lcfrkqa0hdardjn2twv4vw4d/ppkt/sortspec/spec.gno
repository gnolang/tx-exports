// Package sortspec is a sample spec: implement a Sorter.
package sortspec

import (
	"strconv"

	"gno.land/p/g1nx9tjlhjs6ndr3lcfrkqa0hdardjn2twv4vw4d/ppkt/harness"
)

// Sorter is what a submission must provide.
type Sorter interface {
	Sort(xs []int) []int
}

// Factory builds a fresh Sorter for each test.
type Factory func() Sorter

func check(t *harness.T, f Factory, in []int) {
	cp := make([]int, len(in))
	copy(cp, in)
	got := f().Sort(cp)
	if len(got) != len(in) {
		t.Fatal("length " + strconv.Itoa(len(got)) + ", want " + strconv.Itoa(len(in)))
	}
	count := map[int]int{}
	for _, v := range in {
		count[v]++
	}
	for i, v := range got {
		count[v]--
		if i > 0 && got[i-1] > v {
			t.Fatal("not sorted at index " + strconv.Itoa(i))
		}
	}
	for _, c := range count {
		if c != 0 {
			t.Fatal("not a permutation of the input")
		}
	}
}

// Tests returns the suite for an implementation; impl must be a Factory.
func Tests(impl any) []harness.Test {
	f, ok := impl.(Factory)
	if !ok {
		if g, ok2 := impl.(func() Sorter); ok2 {
			f, ok = Factory(g), true
		}
	}
	if !ok {
		return []harness.Test{{Name: "TypeCheck", Fn: func(t *harness.T, _ uint64) { t.Fatal("implementation is not a sortspec.Factory") }}}
	}
	return []harness.Test{
		{"Empty", func(t *harness.T, _ uint64) { check(t, f, []int{}) }},
		{"Example", func(t *harness.T, _ uint64) { check(t, f, []int{3, 1, 2}) }},
		{"Duplicates", func(t *harness.T, _ uint64) { check(t, f, []int{2, 2, 1, 1}) }},
		{"SeededSmall", func(t *harness.T, seed uint64) { check(t, f, randSlice(seed, 8)) }},
		{"SeededLarge", func(t *harness.T, seed uint64) { check(t, f, randSlice(seed^0xabc, 40)) }},
	}
}

func randSlice(seed uint64, n int) []int {
	r := harness.NewRand(seed)
	out := make([]int, n)
	for i := range out {
		out[i] = r.Intn(100) - 50
	}
	return out
}
