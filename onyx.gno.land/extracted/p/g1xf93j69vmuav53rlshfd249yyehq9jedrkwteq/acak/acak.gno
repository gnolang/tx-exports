// Package acak provides auditable, unpredictable commit-reveal randomness for
// Gno.land realms.
//
// Gno.land has no on-chain entropy. A realm that needs an unpredictable value
// must collect one from its users with commit-reveal: participants publish
// sha256(salt || payload) while the salts are still secret, and later publish
// the salts so the seed can be derived and checked by anyone.
//
// acak makes that scheme a single import:
//
//	commitment := acak.Commit(salt, payload)
//	seed       := acak.Seed(commitments, salts, closeHeight)
//	order      := acak.Draw(acak.RNG(seed), n, k)
//
// Every function here is pure: no realm state, no Render, no I/O. The seed is a
// pure function of the revealed material and the close height, so a stored seed
// reproduces the stored draw exactly, forever, for anyone.
//
// This package provides unpredictability and auditability, not secrecy.
// Commitments hide a value only until the salt is revealed; realm state is
// public.
package acak

import (
	"bytes"
	frand "crypto/chacha20/rand"
	"crypto/merkle"
	"crypto/sha256"
	"encoding/binary"
	"math/bits"
	"sort"
)

const (
	// saltSize is the only salt length Commit accepts. A salt shorter than the
	// hash output would let an attacker brute-force a commitment, which would
	// reveal the payload before the reveal phase.
	saltSize = 32

	// seedSize is the only seed length RNG accepts. crypto/chacha20/rand keys
	// ChaCha20 with 32 bytes; any other length is a caller bug, not a value to
	// silently stretch.
	seedSize = 32

	// hashSize is the length of every hash this package produces or consumes.
	hashSize = 32
)

// seedDomain separates this package's seed derivation from every other use of
// SHA-256 on chain. Two realms that both call Seed on the same material get the
// same seed (they must, for auditability), but a seed can never collide with a
// commitment, a Merkle node, or another package's digest.
var seedDomain = []byte("acak/seed/v1")

// Commit returns sha256(salt || payload).
//
// The salt must be exactly 32 bytes of material the committer keeps secret
// until the reveal phase. It panics otherwise: a short or reused salt is the
// single easiest way to make a commitment reversible before the reveal.
func Commit(salt, payload []byte) []byte {
	if len(salt) != saltSize {
		panic("acak: salt must be exactly 32 bytes")
	}
	buf := make([]byte, 0, saltSize+len(payload))
	buf = append(buf, salt...)
	buf = append(buf, payload...)
	sum := sha256.Sum256(buf)
	return sum[:]
}

// Seed derives the 32-byte seed from the revealed commitments and salts,
// bound to closeHeight.
//
// commitments and salts are each sorted before hashing, so a caller cannot
// bias the result by ordering. The sort is over the two multisets
// independently: the seed depends on the set of commitments and the set of
// salts, not on which salt a realm happens to pair with which commitment.
// (Pairing is checked by the realm, per participant, against Commit.)
//
// closeHeight is mixed into the digest, so material harvested from one round
// cannot be replayed into another round that closes at a different height.
//
// Seed panics on an empty commitment set and on a length mismatch. Both are
// caller bugs, and an empty set would produce a seed every observer can
// predict before anyone commits.
func Seed(commitments [][]byte, salts [][]byte, closeHeight int64) []byte {
	if len(commitments) == 0 {
		panic("acak: Seed requires at least one commitment")
	}
	if len(salts) != len(commitments) {
		panic("acak: commitments and salts must have equal length")
	}

	cs := sortedCopy(commitments)
	ss := sortedCopy(salts)

	buf := make([]byte, 0, len(seedDomain)+8+4+len(cs)*(4+hashSize)+4+len(ss)*(4+hashSize))
	buf = append(buf, seedDomain...)
	buf = appendUint64(buf, uint64(closeHeight))
	buf = appendItems(buf, cs)
	buf = appendItems(buf, ss)

	sum := sha256.Sum256(buf)
	return sum[:]
}

// RNG returns a ChaCha20-backed generator seeded with seed.
//
// It panics if len(seed) != 32. The generator is deterministic: the same seed
// always produces the same stream, which is what makes a stored draw
// replayable by an auditor.
func RNG(seed []byte) *frand.RNG {
	if len(seed) != seedSize {
		panic("acak: seed must be exactly 32 bytes")
	}
	// Copy so a caller mutating their slice cannot change a generator that has
	// already been handed out.
	key := make([]byte, seedSize)
	copy(key, seed)
	return frand.NewFromSeed(key)
}

// Perm returns a uniformly random permutation of [0,n) via Fisher-Yates.
//
// The pass runs forward from position 0, so the first k positions are decided
// by the first k draws. That makes Draw(rng,n,k) exactly Perm(rng,n)[:k] for the
// same generator state, and lets an auditor replay a partial draw.
func Perm(rng *frand.RNG, n int) []int {
	if rng == nil {
		panic("acak: Perm requires a non-nil RNG")
	}
	if n < 0 {
		panic("acak: Perm requires n >= 0")
	}
	m := make([]int, n)
	for i := 0; i < n; i++ {
		m[i] = i
	}
	shufflePrefix(rng, m, n)
	return m
}

// Draw returns k distinct indices from [0,n), in draw order.
//
// It is the first k positions of Perm for the same seed: the same generator
// state yields the same values, and only k draws are consumed.
//
// It panics if n <= 0, if k < 0, or if k > n: a draw of nothing from nothing is
// a caller bug, and silently returning an empty slice would let a realm settle
// a round with no winner. k == 0 with n > 0 returns an empty slice.
func Draw(rng *frand.RNG, n, k int) []int {
	if rng == nil {
		panic("acak: Draw requires a non-nil RNG")
	}
	if n <= 0 {
		panic("acak: Draw requires n > 0")
	}
	if k < 0 || k > n {
		panic("acak: Draw requires 0 <= k <= n")
	}

	pool := make([]int, n)
	for i := 0; i < n; i++ {
		pool[i] = i
	}
	shufflePrefix(rng, pool, k)
	out := make([]int, k)
	copy(out, pool[:k])
	return out
}

// shufflePrefix performs the first `steps` iterations of a forward Fisher-Yates
// shuffle over m: for i in [0,steps), swap m[i] with a uniform choice from
// [i,len(m)). Exactly `steps` values are drawn from rng, so a prefix of the
// shuffle consumes a prefix of the stream.
func shufflePrefix(rng *frand.RNG, m []int, steps int) {
	for i := 0; i < steps; i++ {
		j := i + rng.Intn(len(m)-i)
		m[i], m[j] = m[j], m[i]
	}
}

// Tree is a Tendermint simple Merkle tree over arbitrary leaves.
//
// The constructor is NewTree rather than Tree: Go and Gno share one package
// namespace, so a package cannot declare both a type Tree and a function Tree.
// The rest of the surface is unchanged.
type Tree struct {
	leaves [][]byte
	root   []byte
}

// NewTree builds a Merkle tree over leaves using merkle.LeafHash and
// merkle.InnerHash.
//
// The tree is exactly Tendermint's simple tree: the split point is the largest
// power of two strictly less than the number of items, so Root always equals
// crypto/merkle.HashFromByteSlices for the same items in the same order.
// Leaves are copied so later mutation by the caller cannot change the tree.
func NewTree(leaves [][]byte) *Tree {
	t := &Tree{leaves: make([][]byte, len(leaves))}
	for i, leaf := range leaves {
		cp := make([]byte, len(leaf))
		copy(cp, leaf)
		t.leaves[i] = cp
	}
	if len(t.leaves) > 0 {
		t.root = rootOf(t.leaves)
	}
	return t
}

// Root returns the 32-byte root, or nil for an empty tree.
func (t *Tree) Root() []byte {
	if len(t.root) == 0 {
		return nil
	}
	cp := make([]byte, len(t.root))
	copy(cp, t.root)
	return cp
}

// Prove returns the audit path for leaf i as a flat concatenation of 32-byte
// siblings, plus the total leaf count, in the encoding
// merkle.VerifySimpleProof expects: the leaf's own sibling first, the root's
// child sibling last.
//
// It panics if the tree is empty or i is out of range.
func (t *Tree) Prove(i int) (aunts []byte, total int) {
	if len(t.leaves) == 0 {
		panic("acak: Prove on an empty tree")
	}
	if i < 0 || i >= len(t.leaves) {
		panic("acak: Prove index out of range")
	}
	path := provePath(t.leaves, i)
	out := make([]byte, 0, len(path)*hashSize)
	for _, a := range path {
		out = append(out, a...)
	}
	return out, len(t.leaves)
}

// Verify checks a proof against a root using merkle.VerifySimpleProof.
//
// It returns false rather than panicking on malformed input, so a realm can
// reject a bad proof from an untrusted caller with an error instead of aborting
// the transaction.
func Verify(root, leaf []byte, index, total int, aunts []byte) bool {
	if len(root) != hashSize {
		return false
	}
	if total <= 0 || index < 0 || index >= total {
		return false
	}
	if len(aunts)%hashSize != 0 {
		return false
	}
	return merkle.VerifySimpleProof(root, leaf, index, total, aunts)
}

// rootOf computes the Tendermint simple root of items, which must be non-empty.
func rootOf(items [][]byte) []byte {
	if len(items) == 1 {
		return merkle.LeafHash(items[0])
	}
	k := splitPoint(len(items))
	return merkle.InnerHash(rootOf(items[:k]), rootOf(items[k:]))
}

// provePath returns the sibling hashes from the leaf up to the root's child.
func provePath(items [][]byte, i int) [][]byte {
	if len(items) == 1 {
		return nil
	}
	k := splitPoint(len(items))
	if i < k {
		path := provePath(items[:k], i)
		return append(path, rootOf(items[k:]))
	}
	path := provePath(items[k:], i-k)
	return append(path, rootOf(items[:k]))
}

// splitPoint returns the largest power of two strictly less than length,
// matching tm2's merkle.getSplitPoint.
func splitPoint(length int) int {
	if length < 1 {
		panic("acak: cannot split an empty tree")
	}
	k := 1 << uint(bits.Len(uint(length))-1)
	if k == length {
		k >>= 1
	}
	return k
}

// byteSlices sorts [][]byte lexicographically.
type byteSlices [][]byte

func (b byteSlices) Len() int           { return len(b) }
func (b byteSlices) Less(i, j int) bool { return bytes.Compare(b[i], b[j]) < 0 }
func (b byteSlices) Swap(i, j int)      { b[i], b[j] = b[j], b[i] }

// sortedCopy copies items, then sorts the copy so the caller's slice is never
// reordered underneath them.
func sortedCopy(items [][]byte) [][]byte {
	out := make([][]byte, len(items))
	for i, item := range items {
		cp := make([]byte, len(item))
		copy(cp, item)
		out[i] = cp
	}
	sort.Sort(byteSlices(out))
	return out
}

// appendUint64 appends v as 8 big-endian bytes.
func appendUint64(dst []byte, v uint64) []byte {
	var tmp [8]byte
	binary.BigEndian.PutUint64(tmp[:], v)
	return append(dst, tmp[:]...)
}

// appendItems appends a 4-byte big-endian count followed by each item as a
// 4-byte big-endian length and its bytes. Length prefixes make the encoding
// unambiguous, so no two distinct item lists can produce the same byte string.
func appendItems(dst []byte, items [][]byte) []byte {
	dst = appendUint32(dst, uint32(len(items)))
	for _, item := range items {
		dst = appendUint32(dst, uint32(len(item)))
		dst = append(dst, item...)
	}
	return dst
}

// appendUint32 appends v as 4 big-endian bytes.
func appendUint32(dst []byte, v uint32) []byte {
	var tmp [4]byte
	binary.BigEndian.PutUint32(tmp[:], v)
	return append(dst, tmp[:]...)
}
