// Package factor is a Gauntlet judge: factor a number into primes.
//
// Answers look like "2*2*3*7" (ascending, separated by "*"). Checking an
// answer is cheap: multiply the factors back and test each one for
// primality. Finding them is the work.
package factor

import (
	"strconv"
	"strings"

	"gno.land/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet"
)

const max = 10_000_000

func init(cur realm) {
	gauntlet.RegisterJudge(cross(cur), "Prime factors",
		"Factor n (2 <= n < 10,000,000) as ascending primes joined by *, e.g. 84 -> 2*2*3*7. 6 random n.", Inputs, Check)
}

// Inputs returns 6 random numbers for a seed.
func Inputs(seed uint64) []string {
	r := rng{seed}
	out := make([]string, 0, 6)
	for i := 0; i < 6; i++ {
		n := 2 + r.next()%(max-2)
		out = append(out, strconv.FormatUint(n, 10))
	}
	return out
}

// Check reports whether out is the ascending prime factorization of in.
func Check(in, out string) bool {
	n, err := strconv.ParseUint(in, 10, 64)
	if err != nil || n < 2 {
		return false
	}
	prod := uint64(1)
	prev := uint64(0)
	for _, f := range strings.Split(out, "*") {
		p, err := strconv.ParseUint(strings.TrimSpace(f), 10, 64)
		if err != nil || p < prev || !isPrime(p) {
			return false
		}
		prev = p
		prod *= p
		if prod > n {
			return false
		}
	}
	return prod == n
}

func isPrime(p uint64) bool {
	if p < 2 {
		return false
	}
	for d := uint64(2); d*d <= p; d++ {
		if p%d == 0 {
			return false
		}
	}
	return true
}

type rng struct{ s uint64 }

func (r *rng) next() uint64 {
	r.s += 0x9e3779b97f4a7c15
	z := r.s
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

func Render(_ string) string {
	return "# Prime factors judge\n\nA [Gauntlet](/r/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet:judges) judge. Read the source to see exactly how answers are checked.\n"
}
