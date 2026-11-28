package gen

// rng is splitmix64, the generator's only source of randomness. Every floor
// seeds its own from (day, floor) and the day plan seeds one from (day, 0), so
// a floor depends on nothing but its own seed.
type rng struct{ s uint64 }

// seedMix is xor'd into day<<8 | floor so that day 0 floor 0 is not seed 0.
const seedMix uint64 = 0x5dee7f1a2b3c4d59

func newRng(day uint32, n uint8) rng {
	return rng{s: (uint64(day)<<8 | uint64(n)) ^ seedMix}
}

func (r *rng) next() uint64 {
	r.s += 0x9e3779b97f4a7c15
	z := r.s
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

// intn returns a value in [0, n). n is tiny, so the modulo bias is negligible.
func (r *rng) intn(n int) int {
	if n <= 1 {
		return 0
	}
	return int(r.next() % uint64(n))
}

// span returns a value in [lo, hi].
func (r *rng) span(lo, hi int) int {
	return lo + r.intn(hi-lo+1)
}

func (r *rng) coin() bool {
	return r.next()&1 == 1
}
