// Package bls254 implements BLS signature verification over BN254, plus the
// hash-to-G1 construction and message encoding used by the SPLASH beacon.
//
// Curve: alt_bn128 / BN254. G1: y^2 = x^3 + 3 over Fp. Points are encoded as
// 64 bytes (x|y), each coordinate 32-byte big-endian. G2 points (as used for
// the publisher's public key and the fixed generator) are 128 bytes,
// EIP-197 wire order: x_imag | x_real | y_imag | y_real.
//
// There is no big-integer type in Gno, so field arithmetic goes through
// crypto/modexp (EIP-198 modular exponentiation) plus hand-rolled 4-limb
// compare/subtract/add for the one modular addition hash-to-G1 needs.
package bls254

import (
	"crypto/bn254"
	"crypto/modexp"
	"crypto/sha256"
	"encoding/hex"
	"math/bits"
	"strconv"
)

// DOMAIN is the hash-to-G1 domain separation tag for the SPLASH beacon.
const DOMAIN = "SPLASH-BEACON-BN254-G1-v1"

const (
	// pHex is the BN254 base field modulus, big-endian.
	pHex = "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47"
	// sqrtExpHex is (P+1)/4, a valid modular square-root exponent because
	// P % 4 == 3.
	sqrtExpHex = "0c19139cb84c680a6e14116da060561765e05aa45a1c72a34f082305b61f3f52"
	// g2GenHex is the canonical G2 generator, EIP-197 wire order
	// (x_imag | x_real | y_imag | y_real).
	g2GenHex = "198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa"
)

var (
	pBytes       = mustDecodeHex(pHex)
	pLimbs       = toLimbs(pBytes)
	sqrtExpBytes = mustDecodeHex(sqrtExpHex)
	g2GenBytes   = mustDecodeHex(g2GenHex)
)

func mustDecodeHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic("bls254: bad constant hex")
	}
	return b
}

// ---- 4-limb (256-bit) field helpers. Inputs/outputs are 32-byte big-endian. ----
//
// Every function in this block is hand-unrolled over the four limbs rather than
// written as a `for i := 0; i < 4; i++` loop. That is not style, it is the second
// largest gas item in the drand path after the field multiply itself. Measured on
// this toolchain, 100 calls with the harness baseline subtracted:
//
//	              looped    unrolled   saved
//	toLimbs       52,705      39,328     25%
//	fromLimbs     58,961      42,308     28%
//	addModP       56,287      49,420     12%
//
// The gno VM charges per interpreted operation, so the loop counter, the bound
// test and the i*8 and 3-i index arithmetic cost real gas on top of the eight
// shift-ors they schedule. halveModP in fieldmul.gno was already unrolled and
// measured 21,035 against addModP's looped 56,287 for strictly more work, which
// is what prompted this.
//
// The saving is smaller than that comparison suggested -- addModP gave back 12%,
// not the 2.5x the halveModP contrast implied, because most of its cost is the
// four bits.Add64 calls and the cmp, not the loop scaffolding. The numbers above
// are measured on this toolchain, not predicted.
//
// The unrolled bodies are mechanical transcriptions of the loops they replace;
// TestLimbHelpersUnrolledMatchLooped in bls254_test.gno keeps a copy of each
// original loop and asserts the two agree on a large operand set, so the
// transcription is checked rather than eyeballed.

func toLimbs(b []byte) [4]uint64 {
	var l [4]uint64
	l[3] = uint64(b[0])<<56 | uint64(b[1])<<48 | uint64(b[2])<<40 | uint64(b[3])<<32 |
		uint64(b[4])<<24 | uint64(b[5])<<16 | uint64(b[6])<<8 | uint64(b[7])
	l[2] = uint64(b[8])<<56 | uint64(b[9])<<48 | uint64(b[10])<<40 | uint64(b[11])<<32 |
		uint64(b[12])<<24 | uint64(b[13])<<16 | uint64(b[14])<<8 | uint64(b[15])
	l[1] = uint64(b[16])<<56 | uint64(b[17])<<48 | uint64(b[18])<<40 | uint64(b[19])<<32 |
		uint64(b[20])<<24 | uint64(b[21])<<16 | uint64(b[22])<<8 | uint64(b[23])
	l[0] = uint64(b[24])<<56 | uint64(b[25])<<48 | uint64(b[26])<<40 | uint64(b[27])<<32 |
		uint64(b[28])<<24 | uint64(b[29])<<16 | uint64(b[30])<<8 | uint64(b[31])
	return l
}

func fromLimbs(l [4]uint64) []byte {
	b := make([]byte, 32)
	v := l[3]
	b[0], b[1], b[2], b[3] = byte(v>>56), byte(v>>48), byte(v>>40), byte(v>>32)
	b[4], b[5], b[6], b[7] = byte(v>>24), byte(v>>16), byte(v>>8), byte(v)
	v = l[2]
	b[8], b[9], b[10], b[11] = byte(v>>56), byte(v>>48), byte(v>>40), byte(v>>32)
	b[12], b[13], b[14], b[15] = byte(v>>24), byte(v>>16), byte(v>>8), byte(v)
	v = l[1]
	b[16], b[17], b[18], b[19] = byte(v>>56), byte(v>>48), byte(v>>40), byte(v>>32)
	b[20], b[21], b[22], b[23] = byte(v>>24), byte(v>>16), byte(v>>8), byte(v)
	v = l[0]
	b[24], b[25], b[26], b[27] = byte(v>>56), byte(v>>48), byte(v>>40), byte(v>>32)
	b[28], b[29], b[30], b[31] = byte(v>>24), byte(v>>16), byte(v>>8), byte(v)
	return b
}

// cmp returns -1, 0, 1 for a<b, a==b, a>b. Most-significant limb first, so the
// common case of a difference in the top limb returns after one comparison.
func cmp(a, b [4]uint64) int {
	if a[3] != b[3] {
		if a[3] < b[3] {
			return -1
		}
		return 1
	}
	if a[2] != b[2] {
		if a[2] < b[2] {
			return -1
		}
		return 1
	}
	if a[1] != b[1] {
		if a[1] < b[1] {
			return -1
		}
		return 1
	}
	if a[0] != b[0] {
		if a[0] < b[0] {
			return -1
		}
		return 1
	}
	return 0
}

func sub(a, b [4]uint64) [4]uint64 {
	var r [4]uint64
	var borrow uint64
	r[0], borrow = bits.Sub64(a[0], b[0], 0)
	r[1], borrow = bits.Sub64(a[1], b[1], borrow)
	r[2], borrow = bits.Sub64(a[2], b[2], borrow)
	r[3], _ = bits.Sub64(a[3], b[3], borrow)
	return r
}

func add(a, b [4]uint64) ([4]uint64, uint64) {
	var r [4]uint64
	var carry uint64
	r[0], carry = bits.Add64(a[0], b[0], 0)
	r[1], carry = bits.Add64(a[1], b[1], carry)
	r[2], carry = bits.Add64(a[2], b[2], carry)
	r[3], carry = bits.Add64(a[3], b[3], carry)
	return r, carry
}

// addModP computes (a + b) mod P for a, b already reduced mod P.
func addModP(a, b, p [4]uint64) [4]uint64 {
	s, carry := add(a, b)
	if carry != 0 || cmp(s, p) >= 0 {
		s = sub(s, p)
	}
	return s
}

// ---- hash-to-G1 ----

// hashToG1 is the non-panicking core of HashToG1. ok is false only if the
// try-and-increment loop exhausts its bound, which does not happen for any
// message with a well-formed hash (probability of exhaustion is ~2^-64).
func hashToG1(msg []byte) (pt []byte, ok bool) {
	pt, _, ok = hashToG1WithCounter(msg)
	return pt, ok
}

// hashToG1WithCounter is hashToG1 plus the retry counter it stopped at,
// exposed for tests that check the counter against testdata/vectors.json.
func hashToG1WithCounter(msg []byte) (pt []byte, ctr int, ok bool) {
	three := [4]uint64{3, 0, 0, 0}
	for ctr := 0; ctr < 64; ctr++ {
		buf := make([]byte, 0, len(DOMAIN)+len(msg)+1)
		buf = append(buf, DOMAIN...)
		buf = append(buf, msg...)
		buf = append(buf, byte(ctr))
		h := sha256.Sum256(buf)

		x := modexp.ModExp(h[:], []byte{1}, pBytes) // reduce mod P
		x3 := modexp.ModExp(x, []byte{3}, pBytes)    // x^3 mod P
		rhs := fromLimbs(addModP(toLimbs(x3), three, pLimbs))

		y := modexp.ModExp(rhs, sqrtExpBytes, pBytes) // candidate sqrt
		y2 := modexp.ModExp(y, []byte{2}, pBytes)
		if !bytesEqual(y2, rhs) {
			continue // not a quadratic residue
		}

		yl := toLimbs(y)
		if negy := sub(pLimbs, yl); cmp(negy, yl) < 0 {
			y = fromLimbs(negy) // canonical branch: numerically smaller root
		}
		out := make([]byte, 0, 64)
		out = append(out, x...)
		out = append(out, y...)
		return out, ctr, true
	}
	return nil, 64, false
}

func bytesEqual(a, b []byte) bool {
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

// HashToG1 maps msg to a G1 point via try-and-increment. Returns 64 bytes
// (x|y). Panics if the loop exhausts its 64-attempt bound.
func HashToG1(msg []byte) []byte {
	pt, ok := hashToG1(msg)
	if !ok {
		panic("bls254: hash_to_g1 exhausted")
	}
	return pt
}

// NegateG1 returns (x, P-y) for a 64-byte G1 point. Returns nil on bad input.
func NegateG1(pt []byte) []byte {
	return negateG1(pt)
}

func negateG1(pt []byte) []byte {
	if len(pt) != 64 {
		return nil
	}
	yl := toLimbs(pt[32:64])
	var zero [4]uint64
	out := make([]byte, 64)
	copy(out[:32], pt[:32])
	if cmp(yl, zero) == 0 {
		// y == 0 has no distinct negation; leave as-is.
		copy(out[32:], pt[32:64])
		return out
	}
	copy(out[32:], fromLimbs(sub(pLimbs, yl)))
	return out
}

// Verify reports whether sig is the BLS signature over msg under pubkey.
// pubkey is 128 bytes (G2, imaginary-first), sig is 64 bytes (G1). Verify is
// total: wrong lengths, unreduced coordinates, off-curve points and an
// invalid precompile result all yield false. It never panics.
func Verify(pubkey, msg, sig []byte) bool {
	if len(pubkey) != 128 || len(sig) != 64 {
		return false
	}
	h, ok := hashToG1(msg)
	if !ok {
		return false
	}
	negH := negateG1(h)
	if negH == nil {
		return false
	}

	in := make([]byte, 0, 384)
	in = append(in, sig...)
	in = append(in, g2GenBytes...)
	in = append(in, negH...)
	in = append(in, pubkey...)
	if len(in) != 384 {
		return false
	}

	out := bn254.PairingCheck(in)
	// PairingCheck returns an empty NON-NIL slice on an invalid point or an
	// unreduced coordinate; checking length (not nilness) is load-bearing.
	if len(out) != bn254.PairingOutputSize {
		return false
	}
	return out[len(out)-1] == 1
}

// RoundMessage builds the canonical message for a beacon round:
// chainID || "|" || decimal(round).
func RoundMessage(chainID string, round int64) []byte {
	return []byte(chainID + "|" + strconv.FormatInt(round, 10))
}
