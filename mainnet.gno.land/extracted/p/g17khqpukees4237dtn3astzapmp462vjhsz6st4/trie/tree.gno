package trie

import "gno.land/p/nt/avl/v0"

// Verify that Tree implements the ITree interface.
var _ avl.ITree = (*Tree)(nil)

// Tree is a prefix tree (trie) keyed by string with values of any type.
// It implements the avl.ITree interface, so it can be used as a drop-in
// alternative to an AVL tree. Keys are ordered lexicographically by theiri
// raw bytes.
//
// The zero Tree is an empty, ready-to-use tree.
type Tree struct {
	root *node
	size int
}

// NewTree creates a new empty trie tree.
func NewTree() *Tree {
	return &Tree{root: &node{}}
}

// Size returns the number of key-value pairs stored in the tree.
func (t *Tree) Size() int {
	return t.size
}

// Has reports whether key exists in the tree.
func (t *Tree) Has(key string) bool {
	if t.root == nil {
		return false
	}

	_, exists := t.root.get(key)
	return exists
}

// Get retrieves the value associated with key.
func (t *Tree) Get(key string) any {
	if t.root == nil {
		return nil
	}

	v, _ := t.root.get(key)
	return v
}

// GetByIndex retrieves the key-value pair at the given index
// in lexicographic order. It panics if index is out of range.
func (t *Tree) GetByIndex(index int) (key string, value any) {
	if index < 0 || index >= t.size {
		panic("trie: index out of range")
	}

	i := 0
	t.root.inorder("", true, func(k string, v any) bool {
		if i == index {
			key, value = k, v
			return true
		}

		i++
		return false
	})
	return key, value
}

// Set inserts or updates a key-value pair.
// It returns true when the key already existed and its value
// was updated, and false when the key was newly inserted.
func (t *Tree) Set(key string, value any) (updated bool) {
	if t.root == nil {
		t.root = &node{}
	}

	updated = t.root.set(key, value)
	if !updated {
		t.size++
	}
	return updated
}

// Remove deletes the pair stored under key.
// It returns the removed value and whether the key was found and removed.
func (t *Tree) Remove(key string) (value any, removed bool) {
	if t.root == nil {
		return nil, false
	}

	value, removed = t.root.remove(key)
	if removed {
		t.size--
	}
	return value, removed
}

// Iterate performs an in-order (ascending) traversal over the keys in the
// range [start, end), start is inclusive and end is exclusive.
// An empty start or end means unbounded on that side.
// Iteration stops when the callback returns true, the method returns whether
// it was stopped that way.
func (t *Tree) Iterate(start, end string, cb avl.IterCbFn) bool {
	if t.root == nil {
		return false
	}

	return t.root.inorder("", true, func(key string, value any) bool {
		if start != "" && key < start {
			return false
		}

		if end != "" && key >= end {
			return false
		}
		return cb(key, value)
	})
}

// ReverseIterate performs a reverse in-order (descending) traversal over the
// keys in the range [start, end], where both start and end are inclusive.
// An empty start or end means unbounded on that side.
// Iteration stops when the callback returns true; the method returns whether
// it was stopped that way.
func (t *Tree) ReverseIterate(start, end string, cb avl.IterCbFn) bool {
	if t.root == nil {
		return false
	}

	return t.root.inorder("", false, func(key string, value any) bool {
		if start != "" && key < start {
			return false
		}

		if end != "" && key > end {
			return false
		}
		return cb(key, value)
	})
}

// IterateByOffset performs an in-order (ascending) traversal that skips the
// first offset keys and then visits up to count keys.
// Iteration stops early when the callback returns true, the method returns
// whether it was stopped that way.
func (t *Tree) IterateByOffset(offset int, count int, cb avl.IterCbFn) bool {
	return t.iterateByOffset(offset, count, true, cb)
}

// ReverseIterateByOffset performs a reverse in-order (descending) traversal
// that skips the first offset keys and then visits up to count keys.
// Iteration stops early when the callback returns true; the method returns whether
// it was stopped that way.
func (t *Tree) ReverseIterateByOffset(offset int, count int, cb avl.IterCbFn) bool {
	return t.iterateByOffset(offset, count, false, cb)
}

func (t *Tree) iterateByOffset(offset, count int, ascending bool, cb avl.IterCbFn) bool {
	if t.root == nil || count <= 0 {
		return false
	}

	skipped, emitted := 0, 0
	stopped := false
	t.root.inorder("", ascending, func(key string, value any) bool {
		if skipped < offset {
			skipped++
			return false
		}

		stopped = cb(key, value)
		emitted++
		return stopped || emitted >= count
	})
	return stopped
}
