package bls254

// RFC 9380 expand_message_xmd, and drand's round-message encoding.
//
// These are the first two pieces of the drand verification path. They are
// separate from the SPLASH beacon's own encoding on purpose: the SPLASH scheme
// hashes chainID || "|" || decimal(round) with SHA-256 and maps to G1 by
// try-and-increment, and drand's evmnet chain does neither of those things. Two
// schemes, two names, no shared helpers that could be pointed at the wrong one.
//
// Everything here is verified against drand's own source rather than against
// documentation:
//
//	drand v2.1.7 crypto/schemes.go, NewPedersenBLSBN254UnchainedOnG1Scheme:
//	  Pairing.SetDomainG1([]byte("BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_"))
//	  DigestFunc = keccak256(binary.BigEndian uint64 round)
//
// drand/kyber's *default* BN254 G1 DST is "BN254G1_XMD:KECCAK-256_SSWU_RO_" --
// SSWU, a different map and a different string. It is not what this chain signs
// under, and using it makes every signature fail.

import (
	"crypto/keccak256"
	"crypto/sha256"
)

// DrandDST is the hash-to-curve domain separation tag for drand's
// bls-bn254-unchained-on-g1 scheme (the "evmnet" beacon, chain hash
// 04f1e9062b8a81f848fded9c12306733282b2727ecced50032187751166ec8c3).
const DrandDST = "BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_"

// keccakBlockSize is Keccak-256's input block size, i.e. its sponge rate:
// 1600 bits of state minus 2*256 bits of capacity = 1088 bits = 136 bytes.
// RFC 9380's Z_pad is I2OSP(0, s_in_bytes) with s_in_bytes = this value.
//
// 136, not 64. SHA-2's 64-byte block is the number most expand_message_xmd
// implementations are written against, and drand/kyber, the randa-mu Solidity
// reference and gnark all use the hash's own BlockSize() here, which for
// Keccak-256 is 136.
const keccakBlockSize = 136

// sha256BlockSize is SHA-256's input block size, used only by the tests that
// replay RFC 9380's published SHA-256 expand_message_xmd vectors.
const sha256BlockSize = 64

// expandMessageXMDWith implements expand_message_xmd from RFC 9380 section
// 5.3.1, parameterised on the hash and on that hash's input block size.
//
// The parameterisation exists for one reason: RFC 9380 publishes
// expand_message_xmd test vectors for SHA-256 and SHA-512 but not for
// Keccak-256, so the only way to check this construction against the RFC's own
// numbers is to run it with SHA-256. TestExpandMessageXMDRFC9380 does exactly
// that. Production callers go through expandMessageXMD, which fixes the hash to
// Keccak-256.
//
// Returns nil rather than a short or wrong answer on any input the RFC forbids:
// n outside [1, 65535], ell above 255, or a DST longer than 255 bytes.
func expandMessageXMDWith(sum func([]byte) [32]byte, sInBytes int, msg, dst []byte, n int) []byte {
	if n <= 0 || n > 65535 || len(dst) > 255 || sInBytes <= 0 {
		return nil
	}
	const bInBytes = 32 // both SHA-256 and Keccak-256 produce 32 bytes
	ell := (n + bInBytes - 1) / bInBytes
	if ell > 255 {
		return nil
	}

	// DST_prime = DST || I2OSP(len(DST), 1)
	dstPrime := make([]byte, 0, len(dst)+1)
	dstPrime = append(dstPrime, dst...)
	dstPrime = append(dstPrime, byte(len(dst)))

	// b_0 = H(Z_pad || msg || I2OSP(n, 2) || I2OSP(0, 1) || DST_prime)
	buf := make([]byte, 0, sInBytes+len(msg)+3+len(dstPrime))
	buf = append(buf, make([]byte, sInBytes)...) // Z_pad
	buf = append(buf, msg...)
	buf = append(buf, byte(n>>8), byte(n)) // l_i_b_str = I2OSP(n, 2)
	buf = append(buf, 0)                   // I2OSP(0, 1)
	buf = append(buf, dstPrime...)
	b0 := sum(buf)

	// b_1 = H(b_0 || I2OSP(1, 1) || DST_prime)
	buf = make([]byte, 0, bInBytes+1+len(dstPrime))
	buf = append(buf, b0[:]...)
	buf = append(buf, 1)
	buf = append(buf, dstPrime...)
	bi := sum(buf)

	out := make([]byte, 0, ell*bInBytes)
	out = append(out, bi[:]...)

	// b_i = H(strxor(b_0, b_(i-1)) || I2OSP(i, 1) || DST_prime)
	for i := 2; i <= ell; i++ {
		var x [bInBytes]byte
		for j := 0; j < bInBytes; j++ {
			x[j] = b0[j] ^ bi[j]
		}
		buf = make([]byte, 0, bInBytes+1+len(dstPrime))
		buf = append(buf, x[:]...)
		buf = append(buf, byte(i))
		buf = append(buf, dstPrime...)
		bi = sum(buf)
		out = append(out, bi[:]...)
	}
	return out[:n]
}

// expandMessageXMD is expand_message_xmd with H = legacy Keccak-256, which is
// what drand's bn254 scheme uses. Returns n pseudorandom bytes, or nil on input
// the RFC forbids (see expandMessageXMDWith).
//
// Legacy Keccak-256, NOT NIST SHA3-256: the padding differs, and crypto/keccak256
// exists as its own package in the gno stdlib for exactly that reason.
func expandMessageXMD(msg, dst []byte, n int) []byte {
	return expandMessageXMDWith(keccak256.Sum256, keccakBlockSize, msg, dst, n)
}

// expandMessageXMDSHA256 is expand_message_xmd with H = SHA-256. It exists so
// the tests can replay RFC 9380 appendix K.1, and is deliberately not used by
// any verification path.
func expandMessageXMDSHA256(msg, dst []byte, n int) []byte {
	return expandMessageXMDWith(sha256.Sum256, sha256BlockSize, msg, dst, n)
}

// DrandRoundMessage returns the message drand's bls-bn254-unchained-on-g1
// scheme signs for a round: keccak256 of the round number as a big-endian
// uint64. That is drand v2.1.7's DigestBeacon for this scheme, verbatim.
//
// The chain is *unchained*: the previous round's signature is not part of the
// message, so any round can be verified on its own.
//
// Returns nil for a negative round. drand round numbers are uint64 and start at
// 1; a negative value is a caller bug, and silently reinterpreting it as a huge
// unsigned round would produce a message for a round nobody will ever sign.
// Round 0 is encoded normally -- it is a well-defined byte string -- but no
// signature exists for it, so verification will simply fail.
func DrandRoundMessage(round int64) []byte {
	if round < 0 {
		return nil
	}
	u := uint64(round)
	b := []byte{
		byte(u >> 56), byte(u >> 48), byte(u >> 40), byte(u >> 32),
		byte(u >> 24), byte(u >> 16), byte(u >> 8), byte(u),
	}
	h := keccak256.Sum256(b)
	return h[:]
}
