// Package commit is a small commit-reveal helper. A caller stores only the
// hash of a value in one transaction and reveals the value in a later block, so
// the value cannot be copied out of the mempool before it lands.
package commit

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
)

// Version prefixes every preimage so a hash from another scheme never collides.
const Version = "torchbeat/v1"

// Entry is a stored commitment: the hash and the block height it was made at.
type Entry struct {
	Hash   string
	Height int64
}

// Preimage returns "torchbeat/v1|owner|roomID|relic|log|salt" with relic in decimal.
func Preimage(owner, roomID string, relic int, log, salt string) string {
	return Version + "|" + owner + "|" + roomID + "|" + strconv.Itoa(relic) + "|" + log + "|" + salt
}

// Hash returns the lowercase hex sha256 of Preimage. It does not validate salt;
// callers that need a 32 lowercase hex salt must check it themselves.
func Hash(owner, roomID string, relic int, log, salt string) string {
	sum := sha256.Sum256([]byte(Preimage(owner, roomID, relic, log, salt)))
	return hex.EncodeToString(sum[:])
}

// CheckReveal reports whether a reveal at height may proceed against e. It
// returns "" when it may, else the first failing reason in this order:
// "none" (no commitment), "early" (height <= commit height, same block or
// earlier), "expired" (height > e.Height+maxAge), "mismatch" (got != e.Hash).
func CheckReveal(e Entry, height int64, maxAge int64, got string) string {
	switch {
	case e.Hash == "":
		return "none"
	case height <= e.Height:
		return "early"
	case height > e.Height+maxAge:
		return "expired"
	case got != e.Hash:
		return "mismatch"
	}
	return ""
}
