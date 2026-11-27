package assurance

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// LedgerAccumulator is the Accumulator for realm state that grows across transactions: the same RFC 6962 /
// RFC 9162 tree, with the same Size, Root, Leaf, RootAt, Proof and ConsistencyProof results, but its leaves live in
// an AVL tree keyed by index instead of a slice.
//
// A slice's backing array is one stored object, loaded and saved again in full on every append, so a realm-level
// Accumulator made each append cost gas in proportion to the realm's whole history (on gno v1.8.0 about +290k gas
// per prior leaf in Whisper's SendMessage; bench/gas). A tree append writes O(log n) small nodes. Inside a single
// transaction, or for a short-lived tree, use Accumulator: there the slice is cheaper.
//
// The zero value is an empty accumulator, ready to use.
type LedgerAccumulator struct {
	leaves   avl.Tree // leafKey(index) -> [32]byte
	size     uint64
	frontier []subtree
}

// leafKey is the index in fixed-width decimal, so the tree's key order is index order.
func leafKey(index uint64) string {
	s := strconv.FormatUint(index, 10)
	return strings.Repeat("0", 20-len(s)) + s
}

// Size returns the number of appended leaves.
func (a *LedgerAccumulator) Size() uint64 {
	return a.size
}

// Append adds a leaf hash and returns its 0-based index.
func (a *LedgerAccumulator) Append(leaf [32]byte) uint64 {
	index := a.size
	a.leaves.Set(leafKey(index), leaf)
	a.size++
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
func (a *LedgerAccumulator) Root() [32]byte {
	n := len(a.frontier)
	if n == 0 {
		return HashBytes(nil)
	}
	root := a.frontier[n-1].hash
	for i := n - 2; i >= 0; i-- {
		root = NodeHash(a.frontier[i].hash, root)
	}
	return root
}

// Leaf returns the leaf hash at index.
func (a *LedgerAccumulator) Leaf(index uint64) ([32]byte, bool) {
	if index >= a.size {
		return [32]byte{}, false
	}
	return a.leaves.Get(leafKey(index)).([32]byte), true
}

// RootAt returns the Merkle Tree Head over the first size leaves.
func (a *LedgerAccumulator) RootAt(size uint64) ([32]byte, error) {
	if size > a.size {
		return [32]byte{}, errProofRange
	}
	return mth(a.prefix(size)), nil
}

// Proof returns the RFC 6962 audit path for leaf index in a tree of size leaves.
func (a *LedgerAccumulator) Proof(index, size uint64) ([][32]byte, error) {
	if index >= size || size > a.size {
		return nil, errProofRange
	}
	return auditPath(int(index), a.prefix(size)), nil
}

// ConsistencyProof returns the RFC 6962 / RFC 9162 consistency proof that the first `first` leaves are an exact
// prefix of the first `second` leaves.
func (a *LedgerAccumulator) ConsistencyProof(first, second uint64) ([][32]byte, error) {
	if first == 0 || first > second || second > a.size {
		return nil, errProofRange
	}
	return subproof(int(first), a.prefix(second), true), nil
}

// prefix returns the first n leaves, in index order.
func (a *LedgerAccumulator) prefix(n uint64) [][32]byte {
	out := make([][32]byte, 0, n)
	if n == 0 {
		return out
	}
	a.leaves.Iterate(leafKey(0), leafKey(n), func(_ string, v any) bool {
		out = append(out, v.([32]byte))
		return false
	})
	return out
}
