package bls254

// Field multiplication mod P. TWO implementations, and this header records which
// one the drand path uses and the measurement that decided it. PHASE 2 SETTLED
// THIS; please do not re-litigate it from a gas table that came from somewhere
// else, because that is exactly how it went wrong the first time.
//
// The rest of this package gets away with crypto/modexp for every field
// operation it needs, because try-and-increment hash-to-G1 only ever needs
// powers (x^3, sqrt) and one addition. The RFC 9380 SVDW map that the drand
// path needs (see drandcurve.gno) is different: it needs about a dozen general
// products a*b per field element mapped, and modexp cannot multiply two
// distinct operands.
//
// Two ways out:
//
//  1. The identity a*b == ((a+b)^2 - (a-b)^2) / 4, which crypto/modexp can do
//     because it can square. Two native modexp calls, one modular subtraction and
//     a division by 4, which mod P is two halvings and not a third multiply.
//     Implemented below as mulModPIdentity / mulModPLimbs.
//  2. A hand-rolled 4-limb Montgomery multiply over math/bits.Mul64. No native
//     call, 32 64x64 multiplies per montMul. Implemented below as mulModP.
//
// (1) WINS, AND IT IS WHAT drandcurve.gno's fpMul AND fpSqr BIND TO.
//
// Measured on this toolchain (/home/johnny/go/bin/gno, gno v1.2.0 stdlibs) from
// gno test's own per-test GAS line, 100 iterations per test with the 349,766-gas
// empty-test baseline subtracted. The tests are in drandgas_test.gno; re-run them
// rather than trusting these numbers.
//
//	operation                                    gas each
//	mulModP          4-limb Montgomery          2,200,369
//	mulModPIdentity  identity, byte domain        519,791   <- 4.23x cheaper
//	mulModPLimbs     identity, limb domain        387,943
//	sqrModP          Montgomery a*a             2,200,184
//	sqrModPNative    one native modexp             69,602   <- 31.6x cheaper
//	modexp.ModExp(x, 2, P) bare                    23,145
//	modexp.ModExp(x, (P+1)/4, P) bare             134,372
//	toLimbs / fromLimbs                    39,328 / 42,308
//	halveModP                                      21,035
//
// End to end, net of the same baseline:
//
//	                        Montgomery      identity      factor
//	VerifyDrandOnce         63,846,571    13,396,451       4.77x
//	VerifyDrandFour / 4     68,401,101    15,106,773       4.53x
//	HashToG1DrandOnce       62,394,145    12,004,207       5.20x
//	MapToPointSVDWOnce      35,797,798     6,657,484       5.38x
//	r/splash/beacon Publish 74,891,351    16,671,000*      4.49x
//
// THE IDENTITY COLUMN ROSE ON 2026-09-29 AND THE REASON IS ONE LINE OF CODE, NOT DRIFT.
// mulModPLimbs gained the input guard AUDIT-2026-09-28.md finding 21 asked for -- two
// cmp calls against pLimbs, measured at 8,500 gas the pair -- so every multiply costs
// 8,500 more and the end-to-end figures rise by 8,500 times the number of multiplies
// they perform (16 in VerifyDrandOnce, 9 in the SVDW map). VerifyDrand is up 1.0 %.
// The previous figures were 511,291 / 379,443 / 13,260,451 / 14,964,398 / 11,868,207 /
// 6,580,984, and they are recorded here rather than silently replaced so that a reader
// who remembers them learns why they moved. mulModP, sqrModP and sqrModPNative are
// unchanged because the guard is not on their path.
//
// *THE Publish ROW IS DERIVED, NOT RE-ISOLATED, and it is the only number in this file
// that is. A Publish is its own fixed cost plus exactly one VerifyDrand, so it rises by
// the same 136,000; r/splash/beacon's own suite has no single-Publish gas test to read
// it off, and this change may not touch that realm. Re-isolate it there before quoting
// it as measured.
//
// WHY THE ORIGINAL CHOICE WENT THE OTHER WAY. (2) was specified on the strength of
// a gas table reading "modexp: Base 58000 + 24647680*len(mod)/1024", which would
// have made a modexp call cost ~800k. That table is from a different gno revision
// -- this host has two pinned toolchains, and it was read off GnoBuilder's
// c4c72fdd instead of SPLASH's v1.2.0. On v1.2.0 the crypto/modexp row is Base
// 1400, Slope 2200 on SizeModExpWork (a count of modular multiplications) and
// Slope2 3500 per 1024 bytes of modulus: a 254-bit squaring costs 23k, not 800k.
// Interpreted 64-bit limb arithmetic is the expensive thing here, not the native
// call. If you are about to change this back, measure on the toolchain you will
// deploy with first.
//
// MONTGOMERY IS KEPT, NOT DEAD CODE. mulModP is the independent oracle that
// TestMulModPIdentityMatchesMontgomery compares the identity multiply against:
// two implementations sharing no arithmetic, checked byte-for-byte over every
// ordered pair of 15 limb-boundary edge values, the python-derived vector table,
// 120 in-VM pseudorandom pairs and all 11 rejection cases, with the tally
// asserting that a+b wrapping, a-b going negative and both halvings' odd and even
// branches were each actually reached. Deleting mulModP would delete that oracle.
//
// WHAT IS STILL ON THE TABLE, measured rather than guessed. The multiply is now
// dominated by byte<->limb marshalling, not arithmetic: mulModPLimbs is 387,943
// against mulModPIdentity's 519,791, purely because the caller holds limbs. Moving
// mapToPointSVDW itself into the limb domain would save ~132k on each of its ~8
// products and ~120k on each of its ~6 additions, but would cost ~34k on each of
// its ~5 squarings (a squaring is cheapest in the byte domain, where it is one
// bare modexp) and ~42-81k on each of its 3 full exponentiations. Net estimate
// ~1.4M off a 6.66M map, so VerifyDrand ~13.40M -> ~10.5M: a further 21% for a
// rewrite of the most correctness-critical function in the package. Not taken.
//
// AND SUCH A REWRITE WOULD BE THE FIRST REAL LIMB-DOMAIN CALLER OF mulModPLimbs, which
// is precisely who finding 21's guard is for: the byte-domain wrappers would no longer
// be standing between the SVDW map and the unreduced-operand case.
// 0.0165 GNOT a relay is already 4.5x inside the budget that prompted this work.
//
// One cheap, safe win was left on the table deliberately: inlining mac into the
// two loops below measured 360k instead of 503k gas for mul512, a 28% saving.
// mul512 is now off the hot path entirely -- it is only reached through the
// oracle -- so readability of the reduction loop wins outright and mac stays a
// function.
//
// Everything here is unexported. mulModP, mulModPIdentity and sqrModPNative all
// take and return 32-byte big-endian slices, matching modexp and the point
// encodings used everywhere else in this package, and all three return nil for an
// operand that is not exactly 32 bytes or is >= P.

import (
	"crypto/modexp"
	"math/bits"
)

const (
	// pInvNeg64 is -P^{-1} mod 2^64, the Montgomery reduction constant.
	//
	// Derived, not recalled:
	//   python3 -c "p=0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47;
	//               print(hex((-pow(p,-1,1<<256)) % (1<<64)))"
	//   -> 0x87d20782e4866389
	// TestMontgomeryConstants re-derives it inside the VM from pLimbs alone,
	// so a typo here fails the test suite rather than silently producing
	// wrong products.
	pInvNeg64 = 0x87d20782e4866389

	// r2Hex is R^2 mod P where R = 2^256, i.e. 2^512 mod P. montMul(x, r2)
	// converts x into Montgomery form; montMul(x, 1) converts back.
	//
	//   python3 -c "p=0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47;
	//               print('%064x' % pow(2,512,p))"
	r2Hex = "06d89f71cab8351f47ab1eff0a417ff6b5e71911d44501fbf32cfc5b538afa89"
)

var r2Limbs = toLimbs(mustDecodeHex(r2Hex))

// mac returns the 128-bit a*b + c + carryIn as (hi, lo).
//
// It cannot overflow: a*b <= (2^64-1)^2 = 2^128 - 2^65 + 1, so hi <= 2^64 - 2
// and the two carries that can come out of the low word still leave hi below
// 2^64.
func mac(a, b, c, carryIn uint64) (hi, lo uint64) {
	hi, lo = bits.Mul64(a, b)
	var c1 uint64
	lo, c1 = bits.Add64(lo, c, 0)
	hi, _ = bits.Add64(hi, 0, c1)
	lo, c1 = bits.Add64(lo, carryIn, 0)
	hi, _ = bits.Add64(hi, 0, c1)
	return hi, lo
}

// mul512 is the schoolbook 4x4 -> 8 limb product. Limbs are little-endian
// (index 0 least significant), matching toLimbs.
func mul512(a, b [4]uint64) [8]uint64 {
	var t [8]uint64
	for i := 0; i < 4; i++ {
		var carry uint64
		for j := 0; j < 4; j++ {
			carry, t[i+j] = mac(a[j], b[i], t[i+j], carry)
		}
		// t[i+4] has not been written by any earlier i, so this is an
		// assignment rather than an add.
		t[i+4] = carry
	}
	return t
}

// montReduce returns t * R^{-1} mod P for t < P*R, by separated-operand-scanning
// Montgomery reduction.
func montReduce(t [8]uint64) [4]uint64 {
	// hi9 is the notional ninth limb. The loop can carry past t[7] because
	// t + m_i*P*2^(64i) can exceed 2^512 even though the final quotient does
	// not; see the note on the return value below.
	var hi9 uint64

	for i := 0; i < 4; i++ {
		m := t[i] * pInvNeg64
		var carry uint64
		for j := 0; j < 4; j++ {
			carry, t[i+j] = mac(m, pLimbs[j], t[i+j], carry)
		}
		// t[i] is now zero by construction. Propagate the high carry.
		for k := i + 4; k < 8 && carry != 0; k++ {
			t[k], carry = bits.Add64(t[k], carry, 0)
		}
		hi9 += carry
	}

	r := [4]uint64{t[4], t[5], t[6], t[7]}

	// For a, b < P the input to this function is a*b < P^2 < P*R, so the
	// quotient is below P + P^2/R < 2P. P < 2^254, so 2P < 2^255 and hi9 is
	// necessarily zero. Fold it into the reduction condition anyway: if a
	// caller ever feeds an unreduced operand the answer stays in range for
	// the single subtraction below instead of silently losing 2^256.
	if hi9 != 0 || cmp(r, pLimbs) >= 0 {
		r = sub(r, pLimbs)
	}
	return r
}

// montMul returns a*b*R^{-1} mod P for a, b reduced mod P.
func montMul(a, b [4]uint64) [4]uint64 {
	return montReduce(mul512(a, b))
}

// mulModP returns (a*b) mod P. a and b must be 32-byte big-endian values below
// P; the result is 32 bytes big-endian. Returns nil if either input is not
// exactly 32 bytes or is >= P -- an unreduced operand is a caller bug, and
// returning a plausible-looking wrong product for it is the one outcome this
// package cannot afford.
func mulModP(a, b []byte) []byte {
	if len(a) != 32 || len(b) != 32 {
		return nil
	}
	al := toLimbs(a)
	bl := toLimbs(b)
	if cmp(al, pLimbs) >= 0 || cmp(bl, pLimbs) >= 0 {
		return nil
	}
	// montMul(a, b) = a*b*R^{-1}; multiplying that by R^2 gives a*b.
	return fromLimbs(montMul(montMul(al, bl), r2Limbs))
}

// sqrModP returns (a*a) mod P, with the same contract as mulModP.
func sqrModP(a []byte) []byte { return mulModP(a, a) }

// ---- Approach (1): the squaring identity, via native crypto/modexp ----
//
// This is the alternative the header calls the easier one. It is here because it
// is also, measured on this toolchain, the much cheaper one -- see the table at
// the bottom of this file.
//
//	a*b == ((a+b)^2 - (a-b)^2) / 4    (mod P)
//
// The identity is exact over the integers: (a+b)^2 - (a-b)^2 = 4ab. Reducing
// a+b and a-b mod P first does not change their squares mod P, so the numerator
// is congruent to 4ab and the division by 4 -- which mod P means multiplying by
// the inverse of 4, i.e. halving twice -- recovers ab.

// halveModP returns (x / 2) mod P, i.e. x * inverse(2) mod P, for x reduced mod P.
//
// P is odd, so inverse(2) exists. If x is even the integer x/2 is already the
// answer. If x is odd then x+P is even and (x+P)/2 is the answer, because
// 2*((x+P)/2) = x+P == x (mod P).
//
// No overflow: P < 2^254 and x < P, so x+P < 2^255. The carry out of add is
// therefore always zero; it is folded into the shift anyway so that an unreduced
// input cannot silently lose the top bit.
func halveModP(x [4]uint64) [4]uint64 {
	var carry uint64
	if x[0]&1 == 1 {
		x, carry = add(x, pLimbs)
	}
	// Shift right by one, pulling in carry as bit 256.
	var r [4]uint64
	r[0] = x[0]>>1 | x[1]<<63
	r[1] = x[1]>>1 | x[2]<<63
	r[2] = x[2]>>1 | x[3]<<63
	r[3] = x[3]>>1 | carry<<63
	return r
}

// sqrModPNative returns (a*a) mod P using one native modexp, with exactly
// mulModP's input contract: nil unless a is 32 bytes and below P.
//
// modexp.ModExp returns len(modulus) == 32 bytes, left-padded, so the result
// needs no adjustment.
func sqrModPNative(a []byte) []byte {
	if len(a) != 32 {
		return nil
	}
	if cmp(toLimbs(a), pLimbs) >= 0 {
		return nil
	}
	return modexp.ModExp(a, twoBytes, pBytes)
}

// twoBytes is the exponent 2. A one-byte exponent is what modexp's gas row
// charges least for.
var twoBytes = []byte{2}

// mulModPIdentity returns (a*b) mod P via the squaring identity above. Its
// contract is identical to mulModP's, including returning nil for a non-32-byte
// or unreduced operand: TestMulModPIdentityMatchesMontgomery pins the two
// functions to agreeing on every input, rejections included.
func mulModPIdentity(a, b []byte) []byte {
	if len(a) != 32 || len(b) != 32 {
		return nil
	}
	al := toLimbs(a)
	bl := toLimbs(b)
	if cmp(al, pLimbs) >= 0 || cmp(bl, pLimbs) >= 0 {
		return nil
	}

	return fromLimbs(mulModPLimbs(al, bl))
}

// mulModPLimbs is the identity multiply in the limb domain, for callers that
// already hold reduced limbs and want reduced limbs back. Both operands MUST be
// below P, AND SINCE 2026-09-29 THAT IS CHECKED HERE RATHER THAN ASSUMED.
//
// THE DEFECT THAT PUT THE CHECK IN, AUDIT-2026-09-28.md finding 21. This comment used
// to read "there is no check, because the byte-domain wrappers do it and the SVDW map
// only ever feeds it values it has already reduced". Both halves of that were true, and
// the function was still THE ONLY PRODUCER IN THIS PACKAGE THAT WAS NOT FAIL-CLOSED.
// Fed an unreduced b with b > a + P, subModP's `a < b` branch computes a + (P - b), and
// P - b wraps mod 2^256 because b > P -- so the result is NOT congruent to a - b, the
// numerator is not congruent to 4ab, and the function returns A PLAUSIBLE-LOOKING WRONG
// PRODUCT. This package's own header calls that the one outcome it cannot afford: every
// other entry point returns nil rather than a value that is merely probably right.
// mulModP, mulModPIdentity and sqrModPNative all check; this did not.
//
// IT IS A PANIC AND NOT A nil BECAUSE THE RETURN TYPE HAS NO nil. [4]uint64 has no
// invalid value to hand back, and its zero value is a legitimate product, so the only
// fail-closed answer available is to stop. That is the choice hashToFieldDrand and
// hash_to_g1 already make for their own impossible states.
//
// IT IS UNREACHABLE TODAY AND THE GUARD IS THEREFORE A CONTINGENCY, NOT A FIX TO A LIVE
// BUG: the only non-test caller is mulModPIdentity, which performs exactly this
// comparison on the same values first, and drandcurve.gno's fpMul and fpSqr still bind
// to the input-checked mulModPIdentity and sqrModPNative. NOTHING ON THE LIVE PATH
// CHANGED, and the measured cost of the redundant pair of cmp calls is in the header's
// table. What changed is that a FUTURE caller in the limb domain -- which is the whole
// reason this function is factored out at all -- cannot silently get a wrong answer.
//
// This exists because the byte<->limb conversions, not the arithmetic, are what
// this multiply actually costs. toLimbs and fromLimbs measure ~53k and ~58k gas
// each (see drandgas_test.gno); the byte-domain wrapper pays five conversions,
// this core pays the four that the modexp boundary makes unavoidable.
func mulModPLimbs(al, bl [4]uint64) [4]uint64 {
	if cmp(al, pLimbs) >= 0 || cmp(bl, pLimbs) >= 0 {
		panic("bls254: mulModPLimbs: operand is not reduced mod P")
	}

	// s = (a+b) mod P, d = (a-b) mod P. addModP handles the carry out of a+b
	// exceeding P; subModP handles a < b by adding P back.
	s := fromLimbs(addModP(al, bl, pLimbs))
	d := fromLimbs(subModP(al, bl))

	// Two native squarings. Both operands are already reduced.
	s2 := modexp.ModExp(s, twoBytes, pBytes)
	d2 := modexp.ModExp(d, twoBytes, pBytes)

	// n == 4ab (mod P); halve twice to divide by 4.
	n := subModP(toLimbs(s2), toLimbs(d2))
	return halveModP(halveModP(n))
}

// subModP returns (a - b) mod P for a, b reduced mod P.
//
// THE PRECONDITION IS LOAD-BEARING AND IS WHERE FINDING 21 ACTUALLY LIVED. On the
// `a < b` branch it computes a + (P - b), and sub() wraps mod 2^256: so for b > P the
// term P - b is a huge wrong number and the result is not congruent to a - b. There is
// no way to detect that from inside this function -- every [4]uint64 is a valid return
// value -- so the contract is enforced by its callers, and mulModPLimbs states it as a
// panic rather than assuming it.
func subModP(a, b [4]uint64) [4]uint64 {
	if cmp(a, b) >= 0 {
		return sub(a, b)
	}
	// a < b: a - b + P, computed as a + (P - b). P - b is in [1, P] and a is
	// below b <= P-1, so the sum is below P and no carry escapes.
	d, _ := add(a, sub(pLimbs, b))
	return d
}

// negModP returns (-a) mod P for a reduced mod P.
func negModP(a [4]uint64) [4]uint64 {
	var zero [4]uint64
	if cmp(a, zero) == 0 {
		return zero
	}
	return sub(pLimbs, a)
}
