package merkle

import (
	"crypto/sha256"
)

// hashLeaf hashes a single leaf value with a domain-separation prefix.
func hashLeaf(data []byte) []byte {
	buf := make([]byte, 0, len(data)+1)
	buf = append(buf, 0x00)
	buf = append(buf, data...)
	sum := sha256.Sum256(buf)
	return sum[:]
}

// hashNode hashes two child hashes together with a domain-separation prefix.
func hashNode(left []byte, right []byte) []byte {
	buf := make([]byte, 0, len(left)+len(right)+1)
	buf = append(buf, 0x01)
	buf = append(buf, left...)
	buf = append(buf, right...)
	sum := sha256.Sum256(buf)
	return sum[:]
}

// Root computes the Merkle root of a list of leaves.
// Odd nodes at any level are promoted (duplicated is NOT used, to avoid
// second-preimage style ambiguity; instead the lone node carries forward).
func Root(leaves [][]byte) []byte {
	if len(leaves) == 0 {
		panic("merkle: empty leaves")
	}
	level := make([][]byte, len(leaves))
	for i, l := range leaves {
		level[i] = hashLeaf(l)
	}
	for len(level) > 1 {
		next := make([][]byte, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			if i+1 < len(level) {
				next = append(next, hashNode(level[i], level[i+1]))
			} else {
				next = append(next, level[i])
			}
		}
		level = next
	}
	return level[0]
}

// Proof is a single step in a Merkle inclusion proof.
type Proof struct {
	Hash    []byte
	IsRight bool // true if this hash is the right sibling
}

// GenerateProof builds an inclusion proof for the leaf at index `idx`.
func GenerateProof(leaves [][]byte, idx int) []Proof {
	if idx < 0 || idx >= len(leaves) {
		panic("merkle: index out of range")
	}
	level := make([][]byte, len(leaves))
	for i, l := range leaves {
		level[i] = hashLeaf(l)
	}

	proof := []Proof{}
	pos := idx
	for len(level) > 1 {
		next := make([][]byte, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			if i+1 < len(level) {
				if i == pos || i+1 == pos {
					if i == pos {
						proof = append(proof, Proof{Hash: level[i+1], IsRight: true})
					} else {
						proof = append(proof, Proof{Hash: level[i], IsRight: false})
					}
				}
				next = append(next, hashNode(level[i], level[i+1]))
			} else {
				next = append(next, level[i])
			}
		}
		pos = pos / 2
		level = next
	}
	return proof
}

// VerifyProof checks that a leaf, combined with its proof, produces the given root.
func VerifyProof(leaf []byte, proof []Proof, root []byte) bool {
	h := hashLeaf(leaf)
	for _, p := range proof {
		if p.IsRight {
			h = hashNode(h, p.Hash)
		} else {
			h = hashNode(p.Hash, h)
		}
	}
	if len(h) != len(root) {
		return false
	}
	for i := range h {
		if h[i] != root[i] {
			return false
		}
	}
	return true
}
