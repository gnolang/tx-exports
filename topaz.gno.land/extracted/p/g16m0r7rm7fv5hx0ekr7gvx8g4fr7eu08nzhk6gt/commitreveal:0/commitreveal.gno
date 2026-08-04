// Package commitreveal provides a minimal commit-reveal primitive:
// commit to (salt, data) by publishing only their hash, then later
// reveal the actual salt and data for anyone to verify against the
// published commitment. This is the standard way to prevent front-
// running on gno.land -- e.g. sealed-bid auctions, commit-based voting,
// or any scheme where revealing intent early would let others react to
// it before the reveal phase.
//
// This package holds no chain state and does not manage commit/reveal
// deadlines itself -- the importing realm stores the returned [32]byte
// commitment and decides its own phase timing (typically via
// chain/runtime.ChainHeight(), the same way gno.land/p/demo/ratelimit
// takes a caller-supplied block height instead of reading the chain
// itself).
package commitreveal

import (
	"crypto/sha256"
)

const domainPrefix = byte(0x01)

// minSaltLen is a floor on salt entropy. A short salt lets an observer
// brute-force it (combined with a guessed data value) before the reveal
// phase, defeating the whole point of committing first -- so Commit
// refuses to produce a commitment from a salt this short.
const minSaltLen = 16

func hashCommit(salt, data []byte) [32]byte {
	buf := make([]byte, 0, 1+len(salt)+len(data))
	buf = append(buf, domainPrefix)
	buf = append(buf, salt...)
	buf = append(buf, data...)
	return sha256.Sum256(buf)
}

// Commit produces the commitment hash for (salt, data). salt must be at
// least 16 bytes; data must be non-empty. Panics otherwise -- this is
// the "I'm constructing a real commitment" path, so invalid input here
// is a caller bug, not something to fail quietly on.
func Commit(salt, data []byte) [32]byte {
	if len(salt) < minSaltLen {
		panic("commitreveal: salt must be at least 16 bytes for adequate entropy")
	}
	if len(data) == 0 {
		panic("commitreveal: data cannot be empty")
	}
	return hashCommit(salt, data)
}

// Verify checks whether (salt, data) reveals commitHash. Unlike Commit,
// this never panics -- a reveal attempt is untrusted input from
// whoever's revealing, and a malformed one (e.g. a short salt someone
// hand-crafted) should just fail verification, not abort the caller's
// whole transaction.
func Verify(commitHash [32]byte, salt, data []byte) bool {
	if len(salt) < minSaltLen || len(data) == 0 {
		return false
	}
	return hashCommit(salt, data) == commitHash
}
