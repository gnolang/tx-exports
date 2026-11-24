package fairness

// FairDrop sealed-entry primitives: commit–reveal sealing and seed folding.
//
// A draw is fair when nobody — the organizer included — can steer it.
// FairDrop gets there in three steps:
//
//  1. While entries are open, an entrant publishes only a seal: the SHA-256
//     of a secret they generated locally, bound to the entrant id, the event
//     domain (chain + event id) and the entrant's ticket weight.
//  2. When entries close, entrants reveal their secrets. A reveal is accepted
//     only when it re-hashes to the seal already on chain, so nobody can swap
//     their value after seeing the others.
//  3. The seed is the SHA-256 fold of every accepted reveal in canonical
//     (ascending entrant id) order. Whoever folds the same on-chain reveals
//     gets the same seed, and Draw turns that seed into winners
//     deterministically.
//
// What this does not solve, stated plainly: an entrant who never reveals is
// dropped from the draw (their ticket does not count either way), and the
// choice to withhold shifts which leaves the seed folds over. A revealed
// secret cannot be changed, so withholding only ever removes the withholder's
// own chance — it cannot pick someone else's winner. Callers should treat a
// missed reveal as a forfeit and say so in their UI.

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

const (
	// DigestHexLen is the length of a hex-encoded SHA-256 digest.
	DigestHexLen = 64

	// MinSecretLen is the shortest secret a reveal may carry. Shorter secrets
	// are guessable from the public seal and would let a watcher brute-force
	// an entrant's reveal before it lands.
	MinSecretLen = 16

	// MaxSecretLen bounds how much a single reveal may store on chain.
	MaxSecretLen = 256

	// SealDomain is the domain-separation tag of the sealing format.
	SealDomain = "fairdrop/seal/v1"

	// SeedDomain is the domain-separation tag of the seed fold.
	SeedDomain = "fairdrop/seed/v1"
)

// sha256Sum returns the raw 32-byte digest of s.
func sha256Sum(s string) []byte {
	sum := sha256.Sum256([]byte(s))
	return sum[:]
}

func hashHex(s string) string {
	return hex.EncodeToString(sha256Sum(s))
}

// Canonical is the exact string a seal commits to. Binding the entrant id,
// the domain (chain + event) and the weight means a seal cannot be replayed
// in another event or on another chain, cannot be claimed by another entrant,
// and cannot be reused at a different weight.
func Canonical(domain string, entrant string, weight int64, secret string) string {
	return SealDomain + "|" + domain + "|" + entrant + "|" + strconv.FormatInt(weight, 10) + "|" + secret
}

// Digest is the seal of one entry: hex SHA-256 over Canonical.
func Digest(domain string, entrant string, weight int64, secret string) string {
	return hashHex(Canonical(domain, entrant, weight, secret))
}

// VerifySeal reports whether secret opens commit for this entrant, weight and
// domain. Input is normalised (trimmed, lowercased) so a wallet or a human
// pasting an upper-case digest is not turned away.
func VerifySeal(commit string, domain string, entrant string, weight int64, secret string) bool {
	return strings.ToLower(strings.TrimSpace(commit)) == Digest(domain, entrant, weight, secret)
}

// IsDigest reports whether s is a well-formed lower-case hex SHA-256 digest.
func IsDigest(s string) bool {
	if len(s) != DigestHexLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
			continue
		}
		return false
	}
	return true
}

// NormalizeDigest returns the canonical form of a seal as submitted.
func NormalizeDigest(s string) string {
	return strings.ToLower(strings.TrimSpace(s))
}

// ValidSecret reports whether s may be used as a reveal secret: printable
// ASCII without spaces, within the accepted length bounds.
func ValidSecret(s string) bool {
	n := len(s)
	if n < MinSecretLen || n > MaxSecretLen {
		return false
	}
	for i := 0; i < n; i++ {
		if s[i] < 0x21 || s[i] > 0x7e {
			return false
		}
	}
	return true
}

// Leaf is one input of the seed fold: the seal followed by the secret that
// opened it. Leaves are folded in canonical entrant order.
func Leaf(commit string, secret string) string {
	return NormalizeDigest(commit) + ":" + secret
}

// Seed folds the revealed leaves into the draw seed. The domain, chain id and
// event id are part of the fold, so identical reveals in two events give
// different seeds and no seed can be lifted from one event to another.
func Seed(domain string, chainID string, eventID uint64, leaves []string) string {
	b := SeedDomain + "|" + domain + "|" + chainID + "|" + strconv.FormatUint(eventID, 10) + "|"
	for i := 0; i < len(leaves); i++ {
		b += leaves[i] + "|"
	}
	return hashHex(b)
}
