// Package fenwick is an order-statistic Fenwick (binary indexed) tree over
// non-negative int64 weights, backed by avl.Tree so it can live in realm
// state.
//
// It exists to answer one question in O(log N): given a random unit k drawn
// from [0, Total()), which index owns that unit? That is the weighted-raffle
// draw — each index's value is its ticket count, and Select maps a ticket
// number to its owner. The naive version of that answer walks every index
// accumulating values until the running total passes k, which is O(N) and
// will eventually exceed a block's gas limit. Select never walks: it descends
// the tree's binary structure, touching at most ~log2(N) nodes.
//
// DESIGN DECISION — negative deltas are rejected, not supported. Add panics
// on a negative delta and Append panics on a negative initial value. This
// structure is append-and-grow only. The reason is that Select is only
// meaningful while prefix sums are monotonically non-decreasing: with a
// negative value somewhere, "the index owning unit k" is not well defined and
// the binary descent would silently return a wrong owner rather than fail.
// Refusing the input loudly is the only honest option, so a caller that needs
// decreasing weights gets a panic instead of a corrupt draw. The rest of the
// structure (Add, Append, Total, ValueAt, Len) is otherwise a general,
// reusable Fenwick tree.
//
// Complexity: Append O(log N), Add O(log N), Select O(log N), Total O(1),
// ValueAt O(log N) (one avl lookup), Len O(1).
package fenwick

import (
	"math/bits"
	"strconv"

	"gno.land/p/nt/avl/v0"
)

// keyWidth is enough decimal digits for any non-negative int64 (max is
// 9223372036854775807, 19 digits). Keys are fixed-width and zero-padded so
// that avl.Tree's lexicographic key order matches numeric index order; this
// mirrors roundKey in r/splash/beacon.
const keyWidth = 19

const zeroPad = "0000000000000000000"

// indexKey renders i as a fixed-width, zero-padded decimal string.
func indexKey(i int) string {
	s := strconv.Itoa(i)
	if len(s) < keyWidth {
		s = zeroPad[:keyWidth-len(s)] + s
	}
	return s
}

// Tree is an order-statistic Fenwick tree.
//
// Storage is two avl.Trees keyed by index (never a Go map or a slice, so that
// realm state stays deterministic and persistent):
//
//   - values holds the caller-visible value at each 0-based index.
//   - nodes holds the Fenwick partial sums, keyed by 1-based position, where
//     node j covers the value range (j-lsb(j), j].
//
// total is maintained incrementally so Total is O(1).
type Tree struct {
	values *avl.Tree
	nodes  *avl.Tree
	n      int
	total  int64
}

// NewTree returns an empty tree.
func NewTree() *Tree {
	return &Tree{
		values: avl.NewTree(),
		nodes:  avl.NewTree(),
	}
}

// Len returns the number of indices.
func (t *Tree) Len() int {
	return t.n
}

// Total returns the sum of all values. O(1).
func (t *Tree) Total() int64 {
	return t.total
}

// node reads the 1-based Fenwick node at position j. Every position in
// [1, n] is written at Append time, so a live position is always present;
// Has is still checked because avl.Get returns a single value and would
// otherwise type-assert nil on a missing key.
func (t *Tree) node(j int) int64 {
	key := indexKey(j)
	if !t.nodes.Has(key) {
		return 0
	}
	return t.nodes.Get(key).(int64)
}

func (t *Tree) setNode(j int, v int64) {
	t.nodes.Set(indexKey(j), v)
}

// ValueAt returns the value stored at index i. Panics if i is out of range.
func (t *Tree) ValueAt(i int) int64 {
	if i < 0 || i >= t.n {
		panic("fenwick: index out of range")
	}
	key := indexKey(i)
	if !t.values.Has(key) {
		return 0
	}
	return t.values.Get(key).(int64)
}

// lsb returns the lowest set bit of j (j > 0).
func lsb(j int) int {
	return j & -j
}

// Append adds a new index at the end with the given initial value and
// returns its 0-based index. Panics if value is negative: see the
// append-and-grow note in the package doc.
func (t *Tree) Append(value int64) int {
	if value < 0 {
		panic("fenwick: negative value; tree is append-and-grow only")
	}
	t.addTotal(value)

	i := t.n
	t.n++
	t.values.Set(indexKey(i), value)

	// The new 1-based position j covers (j-lsb(j), j]. Seed its node with
	// the new value plus the nodes of the children that decompose
	// (j-lsb(j), j-1], which is O(log N) reads and keeps the invariant
	// without rebuilding anything.
	j := t.n
	sum := value
	for c := j - 1; c > j-lsb(j); c -= lsb(c) {
		sum += t.node(c)
	}
	t.setNode(j, sum)
	return i
}

// Add increases the value at index i by delta. i must be in [0, Len()).
// Panics on a negative delta: this structure is append-and-grow only, and
// silently accepting a decrease would make Select return wrong owners rather
// than fail (see the package doc). A zero delta is accepted and is a no-op.
func (t *Tree) Add(i int, delta int64) {
	if i < 0 || i >= t.n {
		panic("fenwick: index out of range")
	}
	if delta < 0 {
		panic("fenwick: negative delta; tree is append-and-grow only")
	}
	if delta == 0 {
		return
	}
	t.addTotal(delta)

	key := indexKey(i)
	t.values.Set(key, t.ValueAt(i)+delta)

	for j := i + 1; j <= t.n; j += lsb(j) {
		t.setNode(j, t.node(j)+delta)
	}
}

// addTotal accumulates into total, refusing to wrap. An int64 overflow here
// would corrupt every later Select, so it is a panic and not a silent wrap.
func (t *Tree) addTotal(delta int64) {
	if t.total+delta < t.total {
		panic("fenwick: total overflows int64")
	}
	t.total += delta
}

// Prefix returns the sum of values at indices [0, i). Panics if i is outside
// [0, Len()]. O(log N).
func (t *Tree) Prefix(i int) int64 {
	if i < 0 || i > t.n {
		panic("fenwick: index out of range")
	}
	var sum int64
	for j := i; j > 0; j -= lsb(j) {
		sum += t.node(j)
	}
	return sum
}

// Select returns the index owning cumulative unit k, that is the unique i
// with Prefix(i) <= k < Prefix(i+1). Panics if k is outside [0, Total()).
// O(log N): a binary descent over the tree's node positions, never a walk
// over indices.
//
// An index whose value is 0 owns no units and is therefore never returned:
// the descent takes the largest position whose prefix is still <= k, which
// steps past any zero-valued index.
func (t *Tree) Select(k int64) int {
	if k < 0 || k >= t.total {
		panic("fenwick: k out of range")
	}

	// Start from the highest power of two <= n and halve each step.
	pos := 0
	rem := k
	for step := 1 << (bits.Len(uint(t.n)) - 1); step > 0; step >>= 1 {
		next := pos + step
		if next > t.n {
			continue
		}
		v := t.node(next)
		if v <= rem {
			pos = next
			rem -= v
		}
	}
	// pos is the count of indices whose cumulative sum is still <= k, which
	// is exactly the 0-based index owning unit k.
	return pos
}
