package bls254

// BLS verification for drand's bls-bn254-unchained-on-g1 beacon.
//
// The pairing equation is the same one the existing SPLASH Verify uses --
// signatures in G1, public keys in G2, e(sig, G2gen) * e(-H(m), pk) == 1 -- so
// the only thing that differs is how H(m) is built. That is not a small
// difference: see drandcurve.gno.
//
// The G2 generator is shared, and that is not an assumption. drand/kyber
// v1.3.2's twistGen, decoded from its Montgomery form and written in EIP-197
// imaginary-first order (x_imag|x_real|y_imag|y_real), is byte-for-byte the
// g2GenHex constant already in bls254.gno. The published evmnet group key is
// sk*twistGen for the DKG's collective secret, so pairing against g2GenBytes is
// correct for this chain.

import "crypto/bn254"

// verifyPairingG1SigG2Key reports whether e(sig, G2gen) == e(h, pubkey), for a
// 64-byte G1 signature, a 64-byte G1 message point and a 128-byte G2 key in
// EIP-197 wire order.
//
// This DUPLICATES the tail of Verify rather than refactoring Verify to call it.
// The brief allowed either and asked which and why: the live SPLASH beacon
// depends on Verify, the instruction I was given was not to alter an existing
// exported function, and a behaviour-preserving refactor is still an edit to
// code that is in production. Twelve duplicated lines are the cheaper risk.
//
// The duplication is pinned against drift by
// TestVerifyPairingHelperMatchesVerify, which asserts this helper and Verify
// return the same answer for every vector and every reject-vector of the
// existing SPLASH suite. If someone edits one and not the other, that test
// fails.
func verifyPairingG1SigG2Key(pubkey, h, sig []byte) bool {
	if len(pubkey) != 128 || len(sig) != 64 || len(h) != 64 {
		return false
	}
	negH := negateG1(h)
	if negH == nil {
		return false
	}

	in := make([]byte, 0, 2*bn254.PairingChunkSize)
	in = append(in, sig...)
	in = append(in, g2GenBytes...)
	in = append(in, negH...)
	in = append(in, pubkey...)
	if len(in) != 2*bn254.PairingChunkSize {
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

// VerifyDrand reports whether sig is the drand beacon signature for round under
// pubKey, for the bls-bn254-unchained-on-g1 scheme (drand's "evmnet" chain,
// hash 04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3).
//
// pubKey is the 128-byte G2 group public key in EIP-197 wire order
// (x_imag|x_real|y_imag|y_real), which is exactly the byte string the drand
// /info endpoint serves as "public_key". sig is the 64-byte G1 signature from
// /public/<round>. The chain is unchained, so no previous signature is needed.
//
// The randomness for a verified round is sha256(sig) -- the same derivation
// r/splash/beacon already uses. This function deliberately does not compute it:
// verifying and deriving are separate steps and a caller that conflates them
// tends to derive from an unverified signature.
//
// VerifyDrand is total. It never panics, and returns false for every malformed
// input: wrong pubKey or sig length, a negative round, a signature coordinate at
// or above p, an off-curve point, and an invalid precompile result.
//
// This is NOT Verify. Verify implements the SPLASH beacon's own scheme
// (chainID || "|" || decimal(round), SHA-256, try-and-increment hash-to-G1) and
// will reject every real drand signature; VerifyDrand will reject every SPLASH
// one. Pick by which beacon produced the signature, never by which is to hand.
func VerifyDrand(pubKey []byte, round int64, sig []byte) bool {
	if len(pubKey) != 128 || len(sig) != 64 {
		return false
	}
	// Reject unreduced signature coordinates explicitly. bn254.PairingCheck
	// would also reject them, but relying on a native's error behaviour for a
	// validity rule the caller can violate is how that rule stops being checked.
	if cmp(toLimbs(sig[0:32]), pLimbs) >= 0 || cmp(toLimbs(sig[32:64]), pLimbs) >= 0 {
		return false
	}

	msg := DrandRoundMessage(round)
	if msg == nil {
		return false // negative round
	}
	h := HashToG1Drand(msg)
	if h == nil {
		return false
	}
	return verifyPairingG1SigG2Key(pubKey, h, sig)
}
