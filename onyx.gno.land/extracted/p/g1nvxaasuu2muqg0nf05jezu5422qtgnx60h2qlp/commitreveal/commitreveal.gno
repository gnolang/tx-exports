package commitreveal

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
)

const (
	MinSaltLen = 16
	MaxSaltLen = 128
)

// Record holds the commitment and its update metadata.
type Record struct {
	CommitHash   string
	CommittedAt int64
	UpdatedCount int
}

// IsValidHashHex reports whether h is a lowercase SHA-256 digest in hex.
func IsValidHashHex(h string) bool {
	if len(h) != 2*sha256.Size {
		return false
	}
	for i := 0; i < len(h); i++ {
		c := h[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// IsValidSalt reports whether salt has 16 to 128 printable non-whitespace ASCII bytes.
func IsValidSalt(salt string) bool {
	if len(salt) < MinSaltLen || len(salt) > MaxSaltLen {
		return false
	}
	for i := 0; i < len(salt); i++ {
		if salt[i] < 0x21 || salt[i] > 0x7e {
			return false
		}
	}
	return true
}

// ComputeHash returns the lowercase SHA-256 digest of the byte-length-prefixed fields.
func ComputeHash(domain, roundKey, caller, payload, salt string) string {
	var preimage strings.Builder
	for i, field := range [...]string{domain, roundKey, caller, payload, salt} {
		if i > 0 {
			preimage.WriteByte('|')
		}
		preimage.WriteString(strconv.Itoa(len(field)))
		preimage.WriteByte(':')
		preimage.WriteString(field)
	}
	digest := sha256.Sum256([]byte(preimage.String()))
	return hex.EncodeToString(digest[:])
}

// VerifyReveal checks the salt and hash format and compares the reveal to the commitment.
func VerifyReveal(rec Record, domain, roundKey, caller, payload, salt string) error {
	if !IsValidSalt(salt) || !IsValidHashHex(rec.CommitHash) ||
		ComputeHash(domain, roundKey, caller, payload, salt) != rec.CommitHash {
		return errors.New("ERR_HASH_MISMATCH")
	}
	return nil
}

// CanPrune reports whether the reveal deadline has been reached.
func CanPrune(revealDeadline, nowUnix int64) bool {
	return nowUnix >= revealDeadline
}
