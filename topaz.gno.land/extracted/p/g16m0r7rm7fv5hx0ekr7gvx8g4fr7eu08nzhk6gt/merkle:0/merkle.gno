// Package merkle provides merkle tree construction and proof
// verification. Leaf and internal-node hashes use different domain
// separation prefixes (0x00 vs 0x01) so a proof can never confuse a leaf
// hash for an internal node hash or vice versa -- a classic merkle tree
// forgery vector if left unguarded.
//
// Odd-sized levels promote the unpaired node unchanged to the next level
// (rather than duplicating the last node), which avoids the known
// duplicate-leaf ambiguity issue some naive merkle implementations have.
package merkle

import (
	"crypto/sha256"
)

const (
	leafPrefix byte = 0x00
	nodePrefix byte = 0x01
)

// ProofStep is one step of an audit path: the sibling hash, and whether
// that sibling belongs on the right (true) or left (false) when combined
// with the running hash.
type ProofStep struct {
	Hash           [32]byte
	IsRightSibling bool
}

// HashLeaf hashes raw leaf data with the leaf domain prefix. Callers
// should always go through this rather than hashing data directly, or
// the tree loses its leaf/node domain separation.
func HashLeaf(data []byte) [32]byte {
	buf := make([]byte, 0, len(data)+1)
	buf = append(buf, leafPrefix)
	buf = append(buf, data...)
	return sha256.Sum256(buf)
}

func hashNode(left, right [32]byte) [32]byte {
	buf := make([]byte, 0, 1+64)
	buf = append(buf, nodePrefix)
	buf = append(buf, left[:]...)
	buf = append(buf, right[:]...)
	return sha256.Sum256(buf)
}

// nextLevel pairs up consecutive nodes and hashes them together. An
// unpaired trailing node (odd-sized level) is carried up unchanged --
// deliberately NOT re-hashed or duplicated, since duplicating it would
// reopen the classic duplicate-leaf forgery issue.
func nextLevel(level [][32]byte) [][32]byte {
	next := make([][32]byte, 0, (len(level)+1)/2)
	for i := 0; i < len(level); i += 2 {
		if i+1 < len(level) {
			next = append(next, hashNode(level[i], level[i+1]))
		} else {
			next = append(next, level[i])
		}
	}
	return next
}

// BuildRoot computes the merkle root from a list of already-leaf-hashed
// values (see HashLeaf). Panics on an empty input -- there's no
// meaningful root for zero leaves.
func BuildRoot(leafHashes [][32]byte) [32]byte {
	if len(leafHashes) == 0 {
		panic("merkle: cannot build a root from zero leaves")
	}

	level := leafHashes
	for len(level) > 1 {
		level = nextLevel(level)
	}
	return level[0]
}

// GenerateProof builds the audit path for the leaf at index. Panics if
// index is out of range for the given leaf set.
func GenerateProof(leafHashes [][32]byte, index int) []ProofStep {
	if len(leafHashes) == 0 {
		panic("merkle: cannot generate a proof for zero leaves")
	}
	if index < 0 || index >= len(leafHashes) {
		panic("merkle: index out of range")
	}

	var proof []ProofStep
	level := leafHashes
	idx := index

	for len(level) > 1 {
		if idx%2 == 0 {
			if idx+1 < len(level) {
				proof = append(proof, ProofStep{Hash: level[idx+1], IsRightSibling: true})
			}
		} else {
			proof = append(proof, ProofStep{Hash: level[idx-1], IsRightSibling: false})
		}
		level = nextLevel(level)
		idx = idx / 2
	}

	return proof
}

// VerifyProof replays the audit path starting from leafHash and checks
// whether it reconstructs root.
func VerifyProof(leafHash [32]byte, proof []ProofStep, root [32]byte) bool {
	current := leafHash
	for _, step := range proof {
		if step.IsRightSibling {
			current = hashNode(current, step.Hash)
		} else {
			current = hashNode(step.Hash, current)
		}
	}
	return current == root
}
