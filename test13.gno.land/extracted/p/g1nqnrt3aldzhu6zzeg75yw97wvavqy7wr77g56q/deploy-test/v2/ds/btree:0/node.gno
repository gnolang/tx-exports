package btree

import "sort"

type node struct {
	keys     []key
	values   []any
	children []*node
	count    int
}

func newNode(maxKeys int) *node {
	return &node{
		keys:   make([]key, 0, maxKeys),
		values: make([]any, 0, maxKeys),
	}
}

func newNodeWithEntry(key key, value any, maxKeys int) *node {
	n := newNode(maxKeys)
	n.insertAt(0, key, value)
	n.refreshCount()
	return n
}

func newNodeWithEntries(keys []key, values []any, maxKeys int) *node {
	n := newNode(maxKeys)
	n.keys = append(n.keys, keys...)
	n.values = append(n.values, values...)
	n.refreshCount()
	return n
}

func (n *node) size() int {
	return len(n.keys)
}

func (n *node) subtreeSize() int {
	if n == nil {
		return 0
	}
	return n.count
}

func (n *node) refreshCount() {
	if n == nil {
		return
	}
	count := n.size()
	for _, child := range n.children {
		count += child.subtreeSize()
	}
	n.count = count
}

func (n *node) numOfChildren() int {
	return len(n.children)
}

func (n *node) isLeaf() bool {
	return n.numOfChildren() == 0
}

func (n *node) firstChild() *node {
	return n.children[0]
}

func (n *node) leftChild(keyIdx int) *node {
	return n.children[keyIdx]
}

func (n *node) rightChild(keyIdx int) *node {
	return n.children[keyIdx+1]
}

func (n *node) lastChild() *node {
	return n.children[len(n.children)-1]
}

func (n *node) lastKey() key {
	return n.keys[n.size()-1]
}

func (n *node) removeFirstChild() {
	n.children = n.children[1:]
}

func (n *node) removeLastChild() {
	n.children = n.children[:n.numOfChildren()-1]
}

func (n *node) lowerBound(key key) (idx int, found bool) {
	// idx is the key index when found, or the child/search index otherwise.
	idx = sort.Search(n.size(), func(i int) bool {
		return !n.keys[i].Less(key)
	})

	if idx >= n.size() || !equalKey(n.keys[idx], key) {
		return idx, false
	}

	return idx, true
}

func (n *node) get(key key) (any, bool) {
	// idx is a child index when the key is not found.
	idx, found := n.lowerBound(key)
	if found {
		return n.values[idx], true
	}
	if len(n.children) == 0 {
		return nil, false
	}
	return n.children[idx].get(key)
}

func (n *node) getAt(keyIdx int) (key, any) {
	return n.keys[keyIdx], n.values[keyIdx]
}

func (n *node) updateIfFound(key key, value any) (int, bool) {
	idx, found := n.lowerBound(key)
	if found {
		n.values[idx] = value
		return idx, true
	}
	return idx, false
}

func (n *node) update(key key, value any) bool {
	idx, found := n.updateIfFound(key, value)
	if found {
		return true
	}
	if n.isLeaf() {
		return false
	}
	return n.children[idx].update(key, value)
}

func (n *node) updateAt(keyIdx int, key key, value any) {
	n.keys[keyIdx] = key
	n.values[keyIdx] = value
}

func (n *node) insertAt(keyIdx int, key key, value any) {
	n.keys = append(n.keys, nil)
	n.values = append(n.values, nil)
	copy(n.keys[keyIdx+1:], n.keys[keyIdx:])
	copy(n.values[keyIdx+1:], n.values[keyIdx:])
	n.keys[keyIdx] = key
	n.values[keyIdx] = value
}

func (n *node) removeAt(keyIdx int) {
	n.keys = append(n.keys[:keyIdx], n.keys[keyIdx+1:]...)
	n.values = append(n.values[:keyIdx], n.values[keyIdx+1:]...)
}

func (n *node) removeChildAt(childIdx int) {
	n.children = append(n.children[:childIdx], n.children[childIdx+1:]...)
}

func (n *node) insertChildAt(childIdx int, child *node) {
	n.children = append(n.children, nil)
	copy(n.children[childIdx+1:], n.children[childIdx:])
	n.children[childIdx] = child
}

func (n *node) setNonFull(key key, value any, maxKeys int) bool {
	// idx is the lower-bound result before it is refined into childIdx.
	idx, updated := n.updateIfFound(key, value)
	if updated {
		return false
	}

	if n.isLeaf() {
		n.insertAt(idx, key, value)
		n.count++
		return true
	}

	childIdx := idx
	if n.children[childIdx].size() >= maxKeys {
		n.split(childIdx, maxKeys, n.isAppendToChild(childIdx, key))
		childIdx, updated = n.updateIfFound(key, value)
		if updated {
			return false
		}
	}

	inserted := n.children[childIdx].setNonFull(key, value, maxKeys)
	if inserted {
		n.count++
	}
	return inserted
}

func (n *node) isAppendToChild(childIdx int, key key) bool {
	if childIdx != n.numOfChildren()-1 {
		return false
	}

	child := n.children[childIdx]
	if child.size() == 0 {
		return true
	}
	return child.lastKey().Less(key)
}

func (n *node) split(childIdx int, maxKeys int, appendSplit bool) {
	mid := maxKeys / 2
	if appendSplit {
		mid = maxKeys - 1
	}
	right, promotedKey, promotedValue := n.separate(childIdx, mid, maxKeys)
	n.insertAt(childIdx, promotedKey, promotedValue)
	n.insertChildAt(childIdx+1, right)
	n.refreshCount()
}

func (n *node) separate(childIdx, mid, maxKeys int) (*node, key, any) {
	left := n.children[childIdx]
	right := newNodeWithEntries(left.keys[mid+1:], left.values[mid+1:], maxKeys)

	promotedKey, promotedValue := left.getAt(mid)
	left.keys = left.keys[:mid]
	left.values = left.values[:mid]

	if !left.isLeaf() {
		right.children = append([]*node(nil), left.children[mid+1:]...)
		left.children = left.children[:mid+1]
	}

	left.refreshCount()
	right.refreshCount()
	return right, promotedKey, promotedValue
}

func (n *node) remove(key key, minKeys int) (any, bool) {
	// idx is the key index when found, or the child index to descend into.
	idx, found := n.lowerBound(key)

	if n.isLeaf() {
		if found {
			v := n.values[idx]
			n.removeAt(idx)
			n.count--
			return v, true
		}
		return nil, false
	}

	if found {
		if n.leftChild(idx).size() > minKeys {
			v, removed := n.replaceWithLeftMax(idx, minKeys)
			if removed {
				n.count--
			}
			return v, removed
		}
		if idx < n.numOfChildren()-1 && n.rightChild(idx).size() > minKeys {
			v, removed := n.replaceWithRightMin(idx, minKeys)
			if removed {
				n.count--
			}
			return v, removed
		}
		n.mergeChildren(idx)
		v, removed := n.children[idx].remove(key, minKeys)
		if !removed {
			panic("merged key not found")
		}
		n.count--
		return v, true
	}

	childIdx := idx
	if n.children[childIdx].size() <= minKeys {
		childIdx = n.fill(childIdx, minKeys)
	}
	v, removed := n.children[childIdx].remove(key, minKeys)
	if removed {
		n.count--
	}
	return v, removed
}

func (n *node) replaceWithLeftMax(keyIdx, minKeys int) (any, bool) {
	old := n.values[keyIdx]
	k, v := n.leftChild(keyIdx).removeMax(minKeys)
	n.updateAt(keyIdx, k, v)
	return old, true
}

func (n *node) removeMax(minKeys int) (key, any) {
	if n.isLeaf() {
		lastKeyIdx := n.size() - 1
		k, v := n.getAt(lastKeyIdx)
		n.removeAt(lastKeyIdx)
		n.count--
		return k, v
	}

	if n.lastChild().size() <= minKeys {
		lastChildIdx := n.numOfChildren() - 1
		n.fill(lastChildIdx, minKeys)
	}
	k, v := n.lastChild().removeMax(minKeys)
	n.count--
	return k, v
}

func (n *node) replaceWithRightMin(keyIdx, minKeys int) (any, bool) {
	old := n.values[keyIdx]
	k, v := n.rightChild(keyIdx).removeMin(minKeys)
	n.updateAt(keyIdx, k, v)
	return old, true
}

func (n *node) removeMin(minKeys int) (key, any) {
	if n.isLeaf() {
		k, v := n.getAt(0)
		n.removeAt(0)
		n.count--
		return k, v
	}

	if n.firstChild().size() <= minKeys {
		n.fill(0, minKeys)
	}
	k, v := n.firstChild().removeMin(minKeys)
	n.count--
	return k, v
}

func (n *node) fill(childIdx int, minKeys int) int {
	if childIdx-1 >= 0 && n.children[childIdx-1].size() > minKeys {
		n.borrowFromLeft(childIdx)
		return childIdx
	} else if childIdx+1 < n.numOfChildren() && n.children[childIdx+1].size() > minKeys {
		n.borrowFromRight(childIdx)
		return childIdx
	} else if childIdx+1 < n.numOfChildren() {
		n.mergeChildren(childIdx)
		return childIdx
	} else {
		n.mergeChildren(childIdx - 1)
		return childIdx - 1
	}
}

func (n *node) borrowFromLeft(childIdx int) {
	parentKey, parentValue := n.getAt(childIdx - 1)
	leftSibling := n.children[childIdx-1]
	leftLast := leftSibling.size() - 1
	leftLastKey, leftLastValue := leftSibling.getAt(leftLast)

	child := n.children[childIdx]
	child.insertAt(0, parentKey, parentValue)

	n.updateAt(childIdx-1, leftLastKey, leftLastValue)
	leftSibling.removeAt(leftLast)

	if !leftSibling.isLeaf() {
		child.insertChildAt(0, leftSibling.lastChild())
		leftSibling.removeLastChild()
	}

	leftSibling.refreshCount()
	child.refreshCount()
	n.refreshCount()
}

func (n *node) borrowFromRight(childIdx int) {
	parentKey, parentValue := n.getAt(childIdx)
	rightSibling := n.children[childIdx+1]
	rightFirstKey, rightFirstValue := rightSibling.getAt(0)

	child := n.children[childIdx]
	child.insertAt(child.size(), parentKey, parentValue)

	n.updateAt(childIdx, rightFirstKey, rightFirstValue)
	rightSibling.removeAt(0)

	if !rightSibling.isLeaf() {
		child.insertChildAt(child.numOfChildren(), rightSibling.firstChild())
		rightSibling.removeFirstChild()
	}

	rightSibling.refreshCount()
	child.refreshCount()
	n.refreshCount()
}

func (n *node) mergeChildren(keyIdx int) {
	parentKey := n.keys[keyIdx]
	parentValue := n.values[keyIdx]
	left := n.children[keyIdx]
	right := n.children[keyIdx+1]

	left.keys = append(left.keys, parentKey)
	left.values = append(left.values, parentValue)

	left.keys = append(left.keys, right.keys...)
	left.values = append(left.values, right.values...)

	if !right.isLeaf() {
		left.children = append(left.children, right.children...)
	}

	n.removeAt(keyIdx)
	n.removeChildAt(keyIdx + 1)
	left.refreshCount()
	n.refreshCount()
}

func (n *node) getByIndex(index int) (key, any) {
	rem := index
	for i := 0; i < n.size(); i++ {
		if !n.isLeaf() {
			childSize := n.children[i].subtreeSize()
			if rem < childSize {
				return n.children[i].getByIndex(rem)
			}
			rem -= childSize
		}
		if rem == 0 {
			return n.getAt(i)
		}
		rem--
	}
	if !n.isLeaf() && rem < n.children[n.size()].subtreeSize() {
		return n.children[n.size()].getByIndex(rem)
	}
	panic("GetByIndex asked for invalid index")
}

func (n *node) iterate(start, end key, cb iterCbFn) bool {
	for i := 0; i < n.size(); i++ {
		if !n.isLeaf() {
			if n.children[i].iterate(start, end, cb) {
				return true
			}
		}
		key, value := n.getAt(i)
		if start != nil && key.Less(start) {
			continue
		}
		if end != nil && !key.Less(end) {
			return false
		}
		if cb(key, value) {
			return true
		}
	}
	if !n.isLeaf() {
		return n.children[n.size()].iterate(start, end, cb)
	}
	return false
}

func (n *node) reverseIterate(start, end key, cb iterCbFn) bool {
	for i := n.size(); i >= 0; i-- {
		if !n.isLeaf() {
			if n.children[i].reverseIterate(start, end, cb) {
				return true
			}
		}
		if i == 0 {
			break
		}

		keyIdx := i - 1
		key, value := n.getAt(keyIdx)
		if end != nil && end.Less(key) {
			continue
		}
		if start != nil && key.Less(start) {
			return false
		}
		if cb(key, value) {
			return true
		}
	}
	return false
}

func (n *node) iterateByOffset(
	offset int,
	limit int,
	reverse bool,
	seen *int,
	visited *int,
	cb iterCbFn,
) bool {
	if n == nil || *visited >= limit {
		return false
	}
	if reverse {
		return n.reverseIterateByOffset(offset, limit, seen, visited, cb)
	}
	return n.forwardIterateByOffset(offset, limit, seen, visited, cb)
}

func (n *node) forwardIterateByOffset(
	offset int,
	limit int,
	seen *int,
	visited *int,
	cb iterCbFn,
) bool {
	for i := 0; i < n.size(); i++ {
		if !n.isLeaf() {
			if visitChildByOffset(n.children[i], offset, limit, false, seen, visited, cb) {
				return true
			}
			if *visited >= limit {
				return false
			}
		}
		if visitKeyByOffset(n.keys[i], n.values[i], offset, limit, seen, visited, cb) {
			return true
		}
		if *visited >= limit {
			return false
		}
	}
	if !n.isLeaf() {
		return visitChildByOffset(n.children[n.size()], offset, limit, false, seen, visited, cb)
	}
	return false
}

func (n *node) reverseIterateByOffset(
	offset int,
	limit int,
	seen *int,
	visited *int,
	cb iterCbFn,
) bool {
	if !n.isLeaf() {
		if visitChildByOffset(n.children[n.size()], offset, limit, true, seen, visited, cb) {
			return true
		}
		if *visited >= limit {
			return false
		}
	}
	for i := n.size() - 1; i >= 0; i-- {
		if visitKeyByOffset(n.keys[i], n.values[i], offset, limit, seen, visited, cb) {
			return true
		}
		if *visited >= limit {
			return false
		}
		if !n.isLeaf() {
			if visitChildByOffset(n.children[i], offset, limit, true, seen, visited, cb) {
				return true
			}
			if *visited >= limit {
				return false
			}
		}
	}
	return false
}

func visitChildByOffset(
	child *node,
	offset int,
	limit int,
	reverse bool,
	seen *int,
	visited *int,
	cb iterCbFn,
) bool {
	if child == nil || *visited >= limit {
		return false
	}
	if *seen+child.subtreeSize() <= offset {
		*seen += child.subtreeSize()
		return false
	}
	return child.iterateByOffset(offset, limit, reverse, seen, visited, cb)
}

func visitKeyByOffset(
	key key,
	value any,
	offset int,
	limit int,
	seen *int,
	visited *int,
	cb iterCbFn,
) bool {
	if *seen < offset {
		*seen++
		return false
	}
	if *visited >= limit {
		return false
	}
	if cb(key, value) {
		return true
	}
	*visited++
	return false
}
