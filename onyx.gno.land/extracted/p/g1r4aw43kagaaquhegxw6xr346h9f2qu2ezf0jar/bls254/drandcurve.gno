package bls254

// RFC 9380 hash_to_field and the Shallue-van de Woestijne map to BN254 G1, as
// used by drand's bls-bn254-unchained-on-g1 scheme.
//
// This is the part of the drand path that differs most from the existing SPLASH
// beacon. SPLASH maps to G1 by try-and-increment: hash, treat the digest as x,
// bump a counter until x^3+3 is a square. drand uses RFC 9380 properly --
// expand_message_xmd to 96 bytes, split into two 48-byte field elements, SVDW
// each onto the curve, add the two points. The two constructions produce
// completely different points for the same message and are not interchangeable.
//
// BN254 G1 is y^2 = x^3 + 3 over Fp, so A = 0 and B = 3. The cofactor is 1, so
// there is no cofactor clearing: every point on the curve is in G1.

import (
	"crypto/bn254"
	"crypto/modexp"
)

// ---- SVDW constants ----
//
// RFC 9380 section 6.6.1 defines, for the curve y^2 = x^3 + A*x + B and a
// non-square-ish parameter Z:
//
//	c1 = g(Z)
//	c2 = -Z / 2
//	c3 = sqrt(-g(Z) * (3*Z^2 + 4*A))     with sgn0(c3) == 0
//	c4 = -4 * g(Z) / (3*Z^2 + 4*A)
//
// With A = 0, B = 3, Z = 1 that collapses to
//
//	g(Z) = Z^3 + A*Z + B = 1 + 3 = 4
//	c1   = 4
//	c2   = -1/2 mod p, which is (p-1)/2 because p is odd
//	c3   = sqrt(-4 * 3) = sqrt(-12) mod p, negated if odd so that sgn0(c3) == 0
//	c4   = -16/3 mod p
//
// I derived the four values from p with python3 rather than copying them:
//
//	p  = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47
//	Z, A, B = 1, 0, 3
//	gZ = (Z**3 + A*Z + B) % p
//	c1 = gZ
//	c2 = (-Z * pow(2, -1, p)) % p
//	d  = (-gZ * (3*Z*Z + 4*A)) % p          # = -12 mod p
//	c3 = pow(d, (p+1)//4, p)                # p % 4 == 3, so this is a sqrt
//	assert c3*c3 % p == d
//	if c3 % 2 == 1: c3 = p - c3             # enforce sgn0(c3) == 0
//	c4 = (-4*gZ * pow(3*Z*Z + 4*A, -1, p)) % p
//
// and then checked them two ways before writing them down:
//
//   - against drand/kyber v1.3.2 pairing/bn254/constants.go, whose c1..c4 are
//     stored in Montgomery form; decoding them by multiplying by R^-1 mod p
//     (R = 2^256) reproduced all four exactly.
//   - against the Solidity reference randa-mu/bls-solidity src/libraries/BLS.sol,
//     whose C1/C2/C3/C4 literals are textually identical to the hex below.
//
// TestSVDWConstants re-derives all four inside the VM from pBytes alone, using
// only modexp and the limb helpers, so none of the above has to be trusted at
// read time.
const (
	// c1 = g(Z) = 4
	c1Hex = "0000000000000000000000000000000000000000000000000000000000000004"
	// c2 = -Z/2 = (p-1)/2
	c2Hex = "183227397098d014dc2822db40c0ac2ecbc0b548b438e5469e10460b6c3e7ea3"
	// c3 = sqrt(-12) mod p, the even root
	c3Hex = "00000000000000016789af3a83522eb353c98fc6b36d713d5d8d1cc5dffffffa"
	// c4 = -16/3 mod p
	c4Hex = "10216f7ba065e00de81ac1e7808072c9dd2b2385cd7b438469602eb24829a9bd"

	// invExpHex is p-2, the exponent for a modular inverse by Fermat. modexp
	// with this exponent is also RFC 9380's inv0: it maps 0 to 0, because
	// 0^(p-2) mod p is 0.
	invExpHex = "30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd45"
	// legExpHex is (p-1)/2, the Legendre symbol exponent. Numerically equal to
	// c2Hex; kept separate because the two mean different things and a future
	// edit to one must not silently change the other.
	legExpHex = "183227397098d014dc2822db40c0ac2ecbc0b548b438e5469e10460b6c3e7ea3"
)

var (
	c1Bytes = mustDecodeHex(c1Hex)
	c2Bytes = mustDecodeHex(c2Hex)
	c3Bytes = mustDecodeHex(c3Hex)
	c4Bytes = mustDecodeHex(c4Hex)

	invExpBytes = mustDecodeHex(invExpHex)
	legExpBytes = mustDecodeHex(legExpHex)

	fpOne   = mustDecodeHex("0000000000000000000000000000000000000000000000000000000000000001")
	fpThree = mustDecodeHex("0000000000000000000000000000000000000000000000000000000000000003")
)

// ---- Fp helpers, all on 32-byte big-endian values reduced mod p ----

func fpAdd(a, b []byte) []byte { return fromLimbs(addModP(toLimbs(a), toLimbs(b), pLimbs)) }
func fpSub(a, b []byte) []byte { return fromLimbs(subModP(toLimbs(a), toLimbs(b))) }
func fpNeg(a []byte) []byte    { return fromLimbs(negModP(toLimbs(a))) }

// fpMul and fpSqr are THE field multiply and square for the drand path. Every
// product in the SVDW map below goes through these two names and nowhere else, so
// the Montgomery-versus-modexp choice is made once, here, with the measurements
// that decided it recorded at the bottom of fieldmul.gno.
//
// Measured on this toolchain, per operation, harness baseline subtracted:
//
//	mulModP        (4-limb Montgomery)     2,200,369 gas
//	mulModPIdentity(squaring identity)       519,791 gas   <- 4.23x cheaper
//	sqrModP        (Montgomery a*a)        2,200,184 gas
//	sqrModPNative  (one native modexp)        69,602 gas   <- 31.6x cheaper
//
// (mulModPIdentity was 511,291 until 2026-09-29; the 8,500 is finding 21's
// unreduced-operand guard inside mulModPLimbs. The ranking is untouched.)
//
// so both names bind to the identity/native pair. mulModP and sqrModP are kept in
// fieldmul.gno as the independent oracle the equivalence test compares against,
// not as dead code.
func fpMul(a, b []byte) []byte { return mulModPIdentity(a, b) }
func fpSqr(a []byte) []byte    { return sqrModPNative(a) }

// fpInv0 is RFC 9380's inv0: the multiplicative inverse, with inv0(0) == 0.
// Fermat's little theorem gives a^(p-2) == a^-1 for a != 0, and modexp maps a
// zero base to zero, which is exactly inv0's extra clause.
func fpInv0(a []byte) []byte { return modexp.ModExp(a, invExpBytes, pBytes) }

// fpSqrt returns a square root of a when one exists. p % 4 == 3, so a^((p+1)/4)
// is a root; callers must have established that a is a square, or check the
// result by squaring it.
func fpSqrt(a []byte) []byte { return modexp.ModExp(a, sqrtExpBytes, pBytes) }

// fpIsSquareNonZero reports whether the Legendre symbol of a is exactly +1, i.e.
// a is a non-zero quadratic residue.
//
// RFC 9380's step 15 uses is_square, which is true for 0 as well. This uses
// "Legendre == 1", which is false for 0, because that is what both reference
// implementations of this exact ciphersuite do: drand/kyber v1.3.2's mapToPoint
// branches on `legendre(g(x1)) == 1`, and randa-mu/bls-solidity's BLS.sol on
// `legendre(g(x1)) == 1`. The two differ only when g(x) == 0, which happens for
// no u any adversary can reach in practice -- but the signers run kyber, so
// matching kyber is what makes signatures verify, and matching the RFC letter
// here would be a consensus bug rather than a fix.
func fpIsSquareNonZero(a []byte) bool {
	return bytesEqual(modexp.ModExp(a, legExpBytes, pBytes), fpOne)
}

// fpCurveRHS evaluates g(x) = x^3 + 3, the right-hand side of the BN254 G1
// equation. Returns nil if x is not a reduced 32-byte field element.
func fpCurveRHS(x []byte) []byte {
	x2 := fpSqr(x)
	if x2 == nil {
		return nil
	}
	x3 := fpMul(x2, x)
	if x3 == nil {
		return nil
	}
	return fpAdd(x3, fpThree)
}

// fpSgn0 is RFC 9380's sgn0 for m == 1: the low bit of the integer
// representation.
func fpSgn0(a []byte) byte { return a[31] & 1 }

// ---- hash_to_field ----

// hashToFieldDST is RFC 9380 hash_to_field with m = 1, count = 2 and L = 48: it
// expands msg to 96 bytes and reduces each 48-byte half mod p.
//
// The mod-p reduction needs no new code: modexp.ModExp(chunk, 1, p) is
// OS2IP(chunk) mod p and returns exactly len(p) == 32 bytes, left-padded.
//
// ok is false only if expandMessageXMD rejects its input, i.e. a DST longer than
// 255 bytes. It cannot be false for DrandDST.
func hashToFieldDST(msg, dst []byte) (u0, u1 [32]byte, ok bool) {
	b := expandMessageXMD(msg, dst, 96)
	if len(b) != 96 {
		return u0, u1, false
	}
	copy(u0[:], modexp.ModExp(b[0:48], []byte{1}, pBytes))
	copy(u1[:], modexp.ModExp(b[48:96], []byte{1}, pBytes))
	return u0, u1, true
}

// hashToFieldDrand is hash_to_field for drand's bn254 G1 ciphersuite: two field
// elements, expand_message_xmd with H = legacy Keccak-256, DST = DrandDST.
//
// Panics only on an unreachable branch: DrandDST is a fixed 43-byte constant and
// the output length is a fixed 96, so expandMessageXMD cannot reject. The panic
// is there so that a future edit which breaks that invariant fails loudly
// instead of returning two zero field elements, which would map to a valid-looking
// point and silently accept the wrong signatures. VerifyDrand does not go through
// this function; it uses hashToFieldDST and stays total.
func hashToFieldDrand(msg []byte) (u0, u1 [32]byte) {
	u0, u1, ok := hashToFieldDST(msg, []byte(DrandDST))
	if !ok {
		panic("bls254: hashToFieldDrand: expand_message_xmd rejected a fixed-size input")
	}
	return u0, u1
}

// ---- map_to_curve ----

// mapToPointSVDW maps one field element to a point on BN254 G1 by the
// Shallue-van de Woestijne method, RFC 9380 section 6.6.1 with Z = 1.
//
// Returns 64 bytes, x|y, each 32-byte big-endian. Returns nil if u is not a
// reduced field element (u >= p), or -- and this should be unreachable -- if the
// result fails the curve equation. The cofactor of BN254 G1 is 1, so the output
// needs no cofactor clearing and is already in the prime-order subgroup.
//
// The step numbering in the comments is RFC 9380's.
func mapToPointSVDW(u [32]byte) []byte {
	ub := u[:]
	if cmp(toLimbs(ub), pLimbs) >= 0 {
		return nil // field element >= p
	}

	// 1-2. tv1 = u^2 * c1
	tv1 := fpMul(fpSqr(ub), c1Bytes)
	if tv1 == nil {
		return nil
	}
	// 3. tv2 = 1 + tv1
	tv2 := fpAdd(fpOne, tv1)
	// 4. tv1 = 1 - tv1
	tv1 = fpSub(fpOne, tv1)
	// 5-6. tv3 = inv0(tv1 * tv2)
	tv3 := fpInv0(fpMul(tv1, tv2))
	// 7-9. tv4 = u * tv1 * tv3 * c3
	tv4 := fpMul(fpMul(fpMul(ub, tv1), tv3), c3Bytes)
	if tv4 == nil {
		return nil
	}
	// 10. x1 = c2 - tv4
	x1 := fpSub(c2Bytes, tv4)
	// 16. x2 = c2 + tv4
	x2 := fpAdd(c2Bytes, tv4)
	// 22-26. x3 = c4 * (tv2^2 * tv3)^2 + Z, with Z = 1
	tv8 := fpMul(fpSqr(tv2), tv3)
	x3 := fpAdd(fpMul(c4Bytes, fpSqr(tv8)), fpOne)

	// 11-21, 27-28. The first of x1, x2, x3 whose g(x) is a non-zero square
	// wins. See fpIsSquareNonZero for why this is Legendre == 1 rather than the
	// RFC's is_square.
	var x, gx []byte
	if g := fpCurveRHS(x1); fpIsSquareNonZero(g) {
		x, gx = x1, g
	} else if g := fpCurveRHS(x2); fpIsSquareNonZero(g) {
		x, gx = x2, g
	} else {
		x, gx = x3, fpCurveRHS(x3)
	}
	if gx == nil {
		return nil
	}

	// 29-33. y = sqrt(g(x))
	y := fpSqrt(gx)
	// 34-35. y gets u's sign.
	if fpSgn0(ub) != fpSgn0(y) {
		y = fpNeg(y)
	}

	// Postcondition. SVDW is supposed to land on the curve unconditionally; if
	// it has not, something above is wrong and returning the point would hand a
	// caller an off-curve "G1 element". Two extra multiplications to never do
	// that. This also catches the g(x3) branch being reached with a non-square,
	// which would make fpSqrt return a non-root.
	if !bytesEqual(fpSqr(y), gx) {
		return nil
	}

	out := make([]byte, 0, 64)
	out = append(out, x...)
	out = append(out, y...)
	return out
}

// ---- hash_to_curve ----

// HashToG1Drand maps msg to a G1 point the way drand's
// bls-bn254-unchained-on-g1 scheme does: RFC 9380 hash_to_curve, SVDW map,
// expand_message_xmd with H = legacy Keccak-256 and
// DST = BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_.
//
// Returns 64 bytes, x|y. Returns nil if anything in the construction fails,
// which for a fixed DST means only that the native G1 addition rejected its
// input -- it never should.
//
// This is NOT HashToG1. HashToG1 is the existing SPLASH beacon's
// try-and-increment construction over a different domain tag, and the two return
// different points for the same message. Callers must not mix them.
func HashToG1Drand(msg []byte) []byte {
	u0, u1, ok := hashToFieldDST(msg, []byte(DrandDST))
	if !ok {
		return nil
	}
	p0 := mapToPointSVDW(u0)
	p1 := mapToPointSVDW(u1)
	if p0 == nil || p1 == nil {
		return nil
	}
	in := make([]byte, 0, bn254.G1AddInputSize)
	in = append(in, p0...)
	in = append(in, p1...)
	sum := bn254.G1Add(in)
	if len(sum) != bn254.G1OutputSize {
		return nil
	}
	return sum
}
