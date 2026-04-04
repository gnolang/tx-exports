// Package btchash provides Bitcoin-specific cryptographic hash primitives.
//
// Bitcoin uses several non-standard hash constructions:
//   - SHA-256d: Double SHA-256, used for block hashes, transaction IDs, Merkle trees
//   - HASH160:  RIPEMD-160(SHA-256(data)), used for legacy addresses
//   - Tagged Hash: SHA-256(SHA-256(tag) || SHA-256(tag) || data), used by Taproot (BIP 340/341)
//
// All functions in this package are deterministic and side-effect free.
// They operate on byte slices and return fixed-size arrays.
//
// References:
//   - Bitcoin whitepaper §7 (Merkle trees)
//   - BIP 340 §3 (Tagged hash specification)
//   - BIP 341 §5 (Taproot tagged hashes: TapTweak, TapLeaf, TapBranch, TapSighash)
package btchash

import (
	"crypto/sha256"
)

// SHA256d computes double SHA-256: SHA-256(SHA-256(data)).
// This is Bitcoin's standard hash function for:
//   - Block header hashes
//   - Transaction IDs (txid)
//   - Merkle tree internal nodes
//
// The double hash construction provides protection against length-extension attacks.
func SHA256d(data []byte) [32]byte {
	first := sha256.Sum256(data)
	return sha256.Sum256(first[:])
}

// SHA256dBytes is a convenience wrapper around SHA256d that returns a byte slice.
func SHA256dBytes(data []byte) []byte {
	h := SHA256d(data)
	return h[:]
}

// TaggedHash computes BIP 340 tagged hash:
//
//	SHA-256(SHA-256(tag) || SHA-256(tag) || data)
//
// Tagged hashes ensure domain separation — the same data under different
// tags produces completely different hashes. This prevents cross-protocol attacks.
//
// Used in Taproot (BIP 341) with tags:
//   - "TapTweak"   — Internal key tweaking
//   - "TapLeaf"    — Tapscript leaf hashing
//   - "TapBranch"  — Tapscript branch hashing
//   - "TapSighash" — Signature hash computation
//   - "BIP0340/challenge" — Schnorr signature challenge
//   - "BIP0340/aux"       — Schnorr signature auxiliary randomness
//   - "BIP0340/nonce"     — Schnorr signature nonce derivation
func TaggedHash(tag string, data []byte) [32]byte {
	tagHash := sha256.Sum256([]byte(tag))

	// Construct: SHA-256(tagHash || tagHash || data)
	// Total input length: 32 + 32 + len(data) = 64 + len(data)
	input := make([]byte, 0, 64+len(data))
	input = append(input, tagHash[:]...)
	input = append(input, tagHash[:]...)
	input = append(input, data...)

	return sha256.Sum256(input)
}

// TaggedHashBytes is a convenience wrapper around TaggedHash that returns a byte slice.
func TaggedHashBytes(tag string, data []byte) []byte {
	h := TaggedHash(tag, data)
	return h[:]
}

// MerkleNodeHash computes the hash of a Merkle tree internal node.
// For Bitcoin's Merkle tree: SHA-256d(left || right)
// where left and right are 32-byte hashes of child nodes.
func MerkleNodeHash(left, right [32]byte) [32]byte {
	var combined [64]byte
	copy(combined[:32], left[:])
	copy(combined[32:], right[:])
	return SHA256d(combined[:])
}

// ReverseBytes returns a copy of the input with bytes in reverse order.
// Bitcoin displays transaction and block hashes in reverse byte order
// compared to their internal representation (little-endian vs display order).
func ReverseBytes(b []byte) []byte {
	reversed := make([]byte, len(b))
	for i, v := range b {
		reversed[len(b)-1-i] = v
	}
	return reversed
}

// ReverseHash reverses a 32-byte hash for display purposes.
// Bitcoin hashes are computed in internal byte order but displayed in reverse.
// Example: Genesis block hash
//
//	Internal: 6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000
//	Display:  000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f
func ReverseHash(h [32]byte) [32]byte {
	var reversed [32]byte
	for i := 0; i < 32; i++ {
		reversed[i] = h[31-i]
	}
	return reversed
}
