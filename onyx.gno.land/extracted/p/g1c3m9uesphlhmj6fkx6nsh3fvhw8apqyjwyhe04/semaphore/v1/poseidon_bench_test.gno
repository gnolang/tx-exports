package semaphore

import (
	"math/bits"
	"testing"
)

// Pure-Gno [4]uint64 field arithmetic (little-endian 64-bit limbs) to benchmark
// optimized interpreted Poseidon(2) permutation cost in GnoVM.

type fe [4]uint64

var frLimbs = fe{0x43e1f593f0000001, 0x2833e84879b97091, 0xb85045b68181585d, 0x30644e72e131a029}

func feCmp(a, b fe) int {
	for i := 3; i >= 0; i-- {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	return 0
}

func feAddMod(a, b fe) fe {
	var res fe
	var c uint64
	res[0], c = bits.Add64(a[0], b[0], 0)
	res[1], c = bits.Add64(a[1], b[1], c)
	res[2], c = bits.Add64(a[2], b[2], c)
	res[3], c = bits.Add64(a[3], b[3], c)
	if c != 0 || feCmp(res, frLimbs) >= 0 {
		var br uint64
		res[0], br = bits.Sub64(res[0], frLimbs[0], 0)
		res[1], br = bits.Sub64(res[1], frLimbs[1], br)
		res[2], br = bits.Sub64(res[2], frLimbs[2], br)
		res[3], _ = bits.Sub64(res[3], frLimbs[3], br)
	}
	return res
}

func feMulMod(a, b fe) fe {
	// 256x256 -> 512-bit product, followed by bit-by-bit shift-reduce mod r
	// (representative of pure-Gno 256-bit modular mul cost).
	var p [8]uint64
	for i := 0; i < 4; i++ {
		var carry uint64
		for j := 0; j < 4; j++ {
			hi, lo := bits.Mul64(a[i], b[j])
			var c1, c2 uint64
			lo, c1 = bits.Add64(p[i+j], lo, 0)
			lo, c2 = bits.Add64(lo, carry, 0)
			p[i+j] = lo
			carry = hi + c1 + c2
		}
		p[i+4] = carry
	}
	// Reduce 512-bit p mod r via 256 shift-and-conditional-subtract steps.
	var rem fe
	for i := 3; i >= 0; i-- {
		rem[i] = p[i+4]
	}
	for bit := 255; bit >= 0; bit-- {
		w := bit / 64
		bIdx := uint(bit % 64)
		inBit := (p[w] >> bIdx) & 1
		// rem = (rem << 1) | inBit
		c0 := rem[0] >> 63
		c1 := rem[1] >> 63
		c2 := rem[2] >> 63
		c3 := rem[3] >> 63
		rem[0] = (rem[0] << 1) | inBit
		rem[1] = (rem[1] << 1) | c0
		rem[2] = (rem[2] << 1) | c1
		rem[3] = (rem[3] << 1) | c2
		if c3 != 0 || feCmp(rem, frLimbs) >= 0 {
			var br uint64
			rem[0], br = bits.Sub64(rem[0], frLimbs[0], 0)
			rem[1], br = bits.Sub64(rem[1], frLimbs[1], br)
			rem[2], br = bits.Sub64(rem[2], frLimbs[2], br)
			rem[3], _ = bits.Sub64(rem[3], frLimbs[3], br)
		}
	}
	return rem
}

func fePow5Mod(x fe) fe {
	x2 := feMulMod(x, x)
	x4 := feMulMod(x2, x2)
	return feMulMod(x4, x)
}

func poseidon2BenchFe(left, right fe) fe {
	state := [3]fe{{}, left, right}
	rc := fe{0x123456789abcdef, 1, 0, 0}
	for round := 0; round < 65; round++ {
		state[0] = feAddMod(state[0], rc)
		state[1] = feAddMod(state[1], rc)
		state[2] = feAddMod(state[2], rc)
		if round < 4 || round >= 61 {
			state[0] = fePow5Mod(state[0])
			state[1] = fePow5Mod(state[1])
			state[2] = fePow5Mod(state[2])
		} else {
			state[0] = fePow5Mod(state[0])
		}
		// 3x3 MDS mix: [2,1,1; 1,2,1; 1,1,2]
		sum := feAddMod(feAddMod(state[0], state[1]), state[2])
		state[0] = feAddMod(sum, state[0])
		state[1] = feAddMod(sum, state[1])
		state[2] = feAddMod(sum, state[2])
	}
	return state[0]
}

func TestPoseidon2GasBenchmark_0_Baseline(t *testing.T) {
	_ = frLimbs
}

func TestPoseidon2GasBenchmark_1_SingleHash(t *testing.T) {
	out := poseidon2BenchFe(fe{111, 0, 0, 0}, fe{222, 0, 0, 0})
	if out[0] == 0 && out[1] == 0 && out[2] == 0 && out[3] == 0 {
		t.Fatalf("unexpected zero poseidon output")
	}
}
