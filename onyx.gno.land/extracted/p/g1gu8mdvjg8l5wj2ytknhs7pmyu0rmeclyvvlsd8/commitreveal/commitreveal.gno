// Package commitreveal implements a minimal commit-reveal scheme.
//
// A commitment is the hex-encoded SHA-256 of the exact byte string
//
//	salt + ":" + payload
//
// The payload stays secret until the revealer publishes payload and salt;
// anyone can then recompute the commitment and check it matches the value
// that was committed earlier. The salt keeps short or guessable payloads
// from being brute-forced against a bare hash of the payload alone.
//
// The package is pure and stateless: it is safe to import from any realm.
package commitreveal

import (
	"crypto/sha256"
	"encoding/hex"
)

// Commit returns the commitment for payload under salt: the lowercase
// hex encoding of SHA-256(salt + ":" + payload).
func Commit(payload string, salt string) string {
	sum := sha256.Sum256([]byte(salt + ":" + payload))
	return hex.EncodeToString(sum[:])
}

// IsCommitment reports whether s has the canonical commitment format:
// exactly 64 lowercase hexadecimal characters.
func IsCommitment(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// Verify reports whether commitment is well-formed and equals the
// commitment recomputed from payload and salt.
func Verify(commitment string, payload string, salt string) bool {
	if !IsCommitment(commitment) {
		return false
	}
	return Commit(payload, salt) == commitment
}
