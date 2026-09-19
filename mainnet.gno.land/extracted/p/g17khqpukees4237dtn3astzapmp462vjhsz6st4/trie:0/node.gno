package trie

// node is a single position in the trie tree
type node struct {
	char     byte    // node's char, unused in the root node
	value    any     // node's value, stored when isKey is true
	isKey    bool    // whether a key terminates at this node
	children []*node // child nodes, kept sorted ascending by char
}

// childIndex returns the index of the child reached by byte c and whether such
// a child exists. When it does not exist, the returned index is the position at
// which a child with byte c must be inserted to keep children sorted.
func (n *node) childIndex(c byte) (int, bool) {
	lo := 0
	hi := len(n.children)
	for lo < hi {
		mid := (lo + hi) / 2

		switch {
		case n.children[mid].char < c:
			lo = mid + 1
		case n.children[mid].char > c:
			hi = mid
		default:
			return mid, true
		}
	}
	return lo, false
}

// get retrieves the value stored under key in the subtree rooted at n.
func (n *node) get(key string) (value any, exists bool) {
	cur := n
	for i := 0; i < len(key); i++ {
		idx, ok := cur.childIndex(key[i])
		if !ok {
			return nil, false
		}

		cur = cur.children[idx]
	}

	if !cur.isKey {
		return nil, false
	}
	return cur.value, true
}

// set inserts or updates key with value. It returns true when the key already
// existed and its value updated, and false when it was newly inserted.
func (n *node) set(key string, value any) (updated bool) {
	cur := n
	for i := 0; i < len(key); i++ {
		c := key[i]
		idx, ok := cur.childIndex(c)
		if ok {
			cur = cur.children[idx]
			continue
		}

		child := &node{char: c}
		cur.children = append(cur.children, nil)
		copy(cur.children[idx+1:], cur.children[idx:])
		cur.children[idx] = child
		cur = child
	}

	if cur.isKey {
		cur.value = value
		return true
	}

	cur.isKey = true
	cur.value = value
	return false
}

// remove deletes key from the subtree rooted at n, pruning any nodes that no
// longer terminate a key and have no children. It returns the removed value and
// whether the key was found.
func (n *node) remove(key string) (value any, removed bool) {
	if key == "" {
		if !n.isKey {
			return nil, false
		}

		value = n.value
		n.isKey = false
		n.value = nil
		return value, true
	}

	idx, ok := n.childIndex(key[0])
	if !ok {
		return nil, false
	}

	child := n.children[idx]
	value, removed = child.remove(key[1:])
	if removed && !child.isKey && len(child.children) == 0 {
		n.children = append(n.children[:idx], n.children[idx+1:]...)
	}
	return value, removed
}

// inorder visits this node (when it terminates a key) and its whole subtree.
// key is the full key spelled from the root to this node. When ascending is
// true keys are produced in lexicographic order, otherwise in reverse. Because
// a key always sorts before any key that extends it, the terminal value is
// emitted before the children when ascending and after them when descending.
// It returns true as soon as cb requests the walk to stop.
func (n *node) inorder(key string, ascending bool, cb func(key string, value any) bool) (stop bool) {
	if ascending {
		if n.isKey && cb(key, n.value) {
			return true
		}

		for _, c := range n.children {
			if c.inorder(key+string([]byte{c.char}), ascending, cb) {
				return true
			}
		}
		return false
	}

	for i := len(n.children) - 1; i >= 0; i-- {
		c := n.children[i]
		if c.inorder(key+string([]byte{c.char}), ascending, cb) {
			return true
		}
	}

	if n.isKey && cb(key, n.value) {
		return true
	}
	return false
}
