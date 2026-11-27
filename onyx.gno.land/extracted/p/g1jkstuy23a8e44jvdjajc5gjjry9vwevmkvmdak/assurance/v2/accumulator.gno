// Package assurance implements the Arobi Assurance Agent SDK, built on Gno.land.
//
// Every agent tool invocation passes through a deterministic, fail-closed pipeline:
//
//   PolicyInputProjection -> PolicyEngine -> DecisionReceipt
//        -> EffectWarrant (single-use) -> ToolHandler -> EffectClosure
//        -> RFC 6962 / RFC 9162 Merkle Accumulator -> Gno.land Anchor
//
// Plaintext secrets never need to touch the chain: every receipt and closure is
// canonically binary-encoded, SHA-256 domain-separated, hash-chained, and provable
// offline with zero trust in the executor.
package assurance

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
)

var (
	errDigest     = errors.New("digest must be 64 lowercase hexadecimal characters")
	errProofRange = errors.New("index must be below size, and size at most the number of leaves")
)

// HashBytes returns SHA-256(data).
func HashBytes(data []byte) [32]byte {
	return sha256.Sum256(data)
}

// HashString returns SHA-256([]byte(s)).
func HashString(s string) [32]byte {
	return sha256.Sum256([]byte(s))
}

// LeafHash is the RFC 6962 / RFC 9162 leaf hash: SHA-256(0x00 || data).
func LeafHash(data []byte) [32]byte {
	buf := make([]byte, 0, 1+len(data))
	buf = append(buf, 0x00)
	buf = append(buf, data...)
	return sha256.Sum256(buf)
}

// NodeHash is the RFC 6962 / RFC 9162 interior node hash: SHA-256(0x01 || left || right).
func NodeHash(left, right [32]byte) [32]byte {
	buf := make([]byte, 0, 65)
	buf = append(buf, 0x01)
	buf = append(buf, left[:]...)
	buf = append(buf, right[:]...)
	return sha256.Sum256(buf)
}

// ParseDigest parses a 64-character lowercase hexadecimal SHA-256 digest.
func ParseDigest(s string) ([32]byte, error) {
	var d [32]byte
	if len(s) != 64 {
		return d, errDigest
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return d, errDigest
		}
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return d, errDigest
	}
	copy(d[:], b)
	return d, nil
}

// Hex formats a 32-byte digest as 64 lowercase hexadecimal characters.
func Hex(d [32]byte) string {
	return hex.EncodeToString(d[:])
}

// ZeroDigest returns the all-zero 32-byte digest.
func ZeroDigest() [32]byte {
	return [32]byte{}
}

// Accumulator is an append-only RFC 6962 / RFC 9162 Merkle tree over 32-byte leaf hashes.
// It maintains a compact power-of-two frontier for O(log n) Root() updates while keeping
// all leaves so historical inclusion proofs can be reconstructed at any past tree size.
type Accumulator struct {
	leaves   [][32]byte
	frontier []subtree
}

type subtree struct {
	hash [32]byte
	size uint64
}

// Size returns the number of appended leaves.
func (a *Accumulator) Size() uint64 {
	return uint64(len(a.leaves))
}

// Append adds a leaf hash and returns its 0-based index.
func (a *Accumulator) Append(leaf [32]byte) uint64 {
	index := uint64(len(a.leaves))
	a.leaves = append(a.leaves, leaf)
	a.frontier = append(a.frontier, subtree{hash: leaf, size: 1})
	for len(a.frontier) >= 2 {
		n := len(a.frontier)
		left, right := a.frontier[n-2], a.frontier[n-1]
		if left.size != right.size {
			break
		}
		a.frontier = append(a.frontier[:n-2], subtree{
			hash: NodeHash(left.hash, right.hash),
			size: left.size * 2,
		})
	}
	return index
}

// Root returns the RFC 6962 Merkle Tree Head over every leaf appended so far.
// The empty tree root is SHA-256("").
func (a *Accumulator) Root() [32]byte {
	n := len(a.frontier)
	if n == 0 {
		return sha256.Sum256(nil)
	}
	root := a.frontier[n-1].hash
	for i := n - 2; i >= 0; i-- {
		root = NodeHash(a.frontier[i].hash, root)
	}
	return root
}

// Leaf returns the leaf hash at index.
func (a *Accumulator) Leaf(index uint64) ([32]byte, bool) {
	if index >= uint64(len(a.leaves)) {
		return [32]byte{}, false
	}
	return a.leaves[index], true
}

// RootAt returns the Merkle Tree Head over the first size leaves.
func (a *Accumulator) RootAt(size uint64) ([32]byte, error) {
	if size > uint64(len(a.leaves)) {
		return [32]byte{}, errProofRange
	}
	return mth(a.leaves[:size]), nil
}

// Proof returns the RFC 6962 audit path for leaf index in a tree of size leaves.
func (a *Accumulator) Proof(index, size uint64) ([][32]byte, error) {
	if index >= size || size > uint64(len(a.leaves)) {
		return nil, errProofRange
	}
	return auditPath(int(index), a.leaves[:size]), nil
}

// VerifyInclusion verifies an RFC 9162 section 2.1.3.2 inclusion proof against root.
func VerifyInclusion(index, size uint64, leaf [32]byte, proof [][32]byte, root [32]byte) bool {
	if index >= size {
		return false
	}
	fn, sn := index, size-1
	r := leaf
	for _, p := range proof {
		if sn == 0 {
			return false
		}
		if fn&1 == 1 || fn == sn {
			r = NodeHash(p, r)
			if fn&1 == 0 {
				for fn&1 == 0 && fn != 0 {
					fn >>= 1
					sn >>= 1
				}
			}
		} else {
			r = NodeHash(r, p)
		}
		fn >>= 1
		sn >>= 1
	}
	return sn == 0 && r == root
}

func mth(leaves [][32]byte) [32]byte {
	n := len(leaves)
	if n == 0 {
		return sha256.Sum256(nil)
	}
	if n == 1 {
		return leaves[0]
	}
	k := splitPoint(n)
	return NodeHash(mth(leaves[:k]), mth(leaves[k:]))
}

func auditPath(m int, leaves [][32]byte) [][32]byte {
	n := len(leaves)
	if n <= 1 {
		return nil
	}
	k := splitPoint(n)
	if m < k {
		return append(auditPath(m, leaves[:k]), mth(leaves[k:]))
	}
	return append(auditPath(m-k, leaves[k:]), mth(leaves[:k]))
}

func splitPoint(n int) int {
	k := 1
	for k*2 < n {
		k *= 2
	}
	return k
}

// ConsistencyProof generates an RFC 6962 / RFC 9162 section 2.1.4.2 logarithmic Merkle
// consistency proof (SUBPROOF) showing that the first `first` leaves form an exact
// append-only prefix of the first `second` leaves.
func (a *Accumulator) ConsistencyProof(first, second uint64) ([][32]byte, error) {
	if first == 0 || first > second || second > uint64(len(a.leaves)) {
		return nil, errProofRange
	}
	return subproof(int(first), a.leaves[:second], true), nil
}

func subproof(m int, leaves [][32]byte, startFromOldRoot bool) [][32]byte {
	n := len(leaves)
	if m == n {
		if startFromOldRoot {
			return nil
		}
		return [][32]byte{mth(leaves)}
	}
	k := splitPoint(n)
	if m <= k {
		return append(subproof(m, leaves[:k], startFromOldRoot), mth(leaves[k:]))
	}
	return append(subproof(m-k, leaves[k:], false), mth(leaves[:k]))
}

// VerifyConsistency verifies an RFC 6962 / RFC 9162 section 2.1.4.2 Merkle consistency
// proof between tree sizes `first` (with root `firstRoot`) and `second` (with root `secondRoot`).
func VerifyConsistency(first, second uint64, firstRoot, secondRoot [32]byte, proof [][32]byte) bool {
	if first == 0 || first > second {
		return false
	}
	if first == second {
		return len(proof) == 0 && firstRoot == secondRoot
	}
	if len(proof) == 0 {
		return false
	}

	var node [32]byte
	idx := 0
	if (first & (first - 1)) == 0 {
		node = firstRoot
	} else {
		node = proof[0]
		idx = 1
	}

	fn := first - 1
	sn := second - 1
	for (fn & 1) == 1 {
		fn >>= 1
		sn >>= 1
	}

	fr := node
	sr := node
	for ; idx < len(proof); idx++ {
		if sn == 0 {
			return false
		}
		c := proof[idx]
		if (fn&1) == 1 || fn == sn {
			fr = NodeHash(c, fr)
			sr = NodeHash(c, sr)
			if (fn & 1) == 0 {
				for (fn&1) == 0 && fn != 0 {
					fn >>= 1
					sn >>= 1
				}
			}
		} else {
			sr = NodeHash(sr, c)
		}
		fn >>= 1
		sn >>= 1
	}
	return sn == 0 && fr == firstRoot && sr == secondRoot
}
