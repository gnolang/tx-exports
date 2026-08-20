package commitreveal

import (
	"crypto/sha256"
)

// ComputeCommitment hashes a secret value together with a salt/nonce,
// producing a commitment that hides the value until revealed.
// commitment = sha256(0x00 || salt || value)
func ComputeCommitment(salt []byte, value []byte) []byte {
	buf := make([]byte, 0, len(salt)+len(value)+1)
	buf = append(buf, 0x00)
	buf = append(buf, salt...)
	buf = append(buf, value...)
	sum := sha256.Sum256(buf)
	return sum[:]
}

// VerifyReveal checks that a revealed (salt, value) pair matches a
// previously stored commitment.
func VerifyReveal(commitment []byte, salt []byte, value []byte) bool {
	computed := ComputeCommitment(salt, value)
	if len(computed) != len(commitment) {
		return false
	}
	for i := range computed {
		if computed[i] != commitment[i] {
			return false
		}
	}
	return true
}

// Phase represents the lifecycle stage of a commit-reveal round.
type Phase int

const (
	PhaseCommit Phase = iota
	PhaseReveal
	PhaseClosed
)

func (p Phase) String() string {
	switch p {
	case PhaseCommit:
		return "commit"
	case PhaseReveal:
		return "reveal"
	case PhaseClosed:
		return "closed"
	default:
		return "unknown"
	}
}

// Round tracks the block-height boundaries for a commit-reveal cycle.
// Consumers embed this in their own realm state and drive phase transitions
// using the chain height they read via chain/runtime.
type Round struct {
	CommitEndsAt int64
	RevealEndsAt int64
}

// NewRound creates a round starting at `now`, with the given commit and
// reveal window lengths (in blocks).
func NewRound(now int64, commitBlocks int64, revealBlocks int64) Round {
	if commitBlocks <= 0 || revealBlocks <= 0 {
		panic("commitreveal: window lengths must be positive")
	}
	return Round{
		CommitEndsAt: now + commitBlocks,
		RevealEndsAt: now + commitBlocks + revealBlocks,
	}
}

// PhaseAt returns which phase the round is in at the given height.
func (r Round) PhaseAt(height int64) Phase {
	switch {
	case height <= r.CommitEndsAt:
		return PhaseCommit
	case height <= r.RevealEndsAt:
		return PhaseReveal
	default:
		return PhaseClosed
	}
}
