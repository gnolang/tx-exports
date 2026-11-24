// Package sortnums is a Gauntlet judge: sort a comma-separated list of
// integers in ascending order.
//
// Inputs are random lists generated from the reveal-time seed, so an answer
// key cannot be prepared in advance. Check verifies the output is sorted and
// is a permutation of the input.
package sortnums

import (
	"strconv"
	"strings"

	"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet"
)

func init(cur realm) {
	gauntlet.RegisterJudge(cross(cur), "Sort numbers",
		"Sort comma-separated integers ascending. 8 random lists of 1-40 numbers.", Inputs, Check)
}

// Inputs returns 8 random lists for a seed.
func Inputs(seed uint64) []string {
	r := rng{seed}
	out := make([]string, 0, 8)
	for i := 0; i < 8; i++ {
		n := 1 + int(r.next()%40)
		nums := make([]string, n)
		for j := range nums {
			nums[j] = strconv.FormatInt(int64(r.next()%2001)-1000, 10)
		}
		out = append(out, strings.Join(nums, ","))
	}
	return out
}

// Check reports whether out is in sorted order and a permutation of in.
func Check(in, out string) bool {
	a, ok1 := parse(in)
	b, ok2 := parse(out)
	if !ok1 || !ok2 || len(a) != len(b) {
		return false
	}
	count := map[int64]int{}
	for _, x := range a {
		count[x]++
	}
	for i, x := range b {
		if i > 0 && b[i-1] > x {
			return false
		}
		count[x]--
		if count[x] < 0 {
			return false
		}
	}
	return true
}

func parse(s string) ([]int64, bool) {
	parts := strings.Split(s, ",")
	out := make([]int64, len(parts))
	for i, p := range parts {
		v, err := strconv.ParseInt(strings.TrimSpace(p), 10, 64)
		if err != nil {
			return nil, false
		}
		out[i] = v
	}
	return out, true
}

// rng is splitmix64: tiny, deterministic, good enough to shuffle test data.
type rng struct{ s uint64 }

func (r *rng) next() uint64 {
	r.s += 0x9e3779b97f4a7c15
	z := r.s
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

func Render(_ string) string {
	return "# Sort numbers judge\n\nA [Gauntlet](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:judges) judge. Read the source to see exactly how answers are checked.\n"
}
