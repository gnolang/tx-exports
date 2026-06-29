package btreeset

import "sort"

type node struct {
	keys     []key
	children []*node
	count    int
}

func newNode(maxKeys int) *node {
	return &node{
		keys: make([]key, 0, maxKeys),
	}
}

func newNodeWithEntry(key key, maxKeys int) *node {
	n := newNode(maxKeys)
	n.insertAt(0, key)
	n.refreshCount()
	return n
}

func newNodeWithEntries(keys []key, maxKeys int) *node {
	n := newNode(maxKeys)
	n.keys = append(n.keys, keys...)
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

func (n *node) has(key key) bool {
	// idx is a child index when the key is not found.
	idx, found := n.lowerBound(key)
	if found {
		return true
	}

	if len(n.children) == 0 {
		return false
	}

	return n.children[idx].has(key)
}

func (n *node) updateAt(keyIdx int, key key) {
	n.keys[keyIdx] = key
}

func (n *node) insertAt(keyIdx int, key key) {
	n.keys = append(n.keys, nil)
	copy(n.keys[keyIdx+1:], n.keys[keyIdx:])
	n.keys[keyIdx] = key
}

func (n *node) insertChildAt(childIdx int, child *node) {
	n.children = append(n.children, nil)
	copy(n.children[childIdx+1:], n.children[childIdx:])
	n.children[childIdx] = child
}

func (n *node) removeAt(keyIdx int) {
	n.keys = append(n.keys[:keyIdx], n.keys[keyIdx+1:]...)
}

func (n *node) removeChildAt(childIdx int) {
	n.children = append(n.children[:childIdx], n.children[childIdx+1:]...)
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

func (n *node) setNonFull(key key, maxKeys int) (inserted bool) {
	// idx is the lower-bound result before it is refined into childIdx.
	idx, found := n.lowerBound(key)
	if found {
		return false
	}

	if n.isLeaf() {
		n.insertAt(idx, key)
		n.count++
		return true
	}

	childIdx := idx
	if n.children[childIdx].size() >= maxKeys {
		n.split(childIdx, maxKeys, n.isAppendToChild(childIdx, key))
		childIdx, found = n.lowerBound(key)
		if found {
			return false
		}
	}

	inserted = n.children[childIdx].setNonFull(key, maxKeys)
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

func (n *node) split(childIdx, maxKeys int, appendSplit bool) {
	right, promotedKey := n.separate(childIdx, maxKeys, appendSplit)
	n.insertAt(childIdx, promotedKey)
	n.insertChildAt(childIdx+1, right)
	n.refreshCount()
}

func (n *node) separate(childIdx, maxKeys int, appendSplit bool) (right *node, promoted key) {
	mid := maxKeys / 2
	if appendSplit {
		mid = maxKeys - 1
	}
	left := n.children[childIdx]
	right = newNodeWithEntries(left.keys[mid+1:], maxKeys)
	promoted = left.keys[mid]
	left.keys = left.keys[:mid]

	if !left.isLeaf() {
		right.children = append([]*node(nil), left.children[mid+1:]...)
		left.children = left.children[:mid+1]
	}

	left.refreshCount()
	right.refreshCount()
	return right, promoted
}

func (n *node) remove(key key, minKeys int) bool {
	// idx is the key index when found, or the child index to descend into.
	idx, found := n.lowerBound(key)

	if n.isLeaf() {
		if found {
			n.removeAt(idx)
			n.count--
			return true
		}
		return false
	}

	if found {
		if n.leftChild(idx).size() > minKeys {
			n.replaceWithLeftMax(idx, minKeys)
			n.count--
			return true
		}

		if idx < n.numOfChildren()-1 && n.rightChild(idx).size() > minKeys {
			n.replaceWithRightMin(idx, minKeys)
			n.count--
			return true
		}

		n.mergeChildren(idx)
		removed := n.children[idx].remove(key, minKeys)
		if !removed {
			panic("merged key not found")
		}
		n.count--
		return true
	}

	childIdx := idx
	if n.children[childIdx].size() <= minKeys {
		childIdx = n.fill(childIdx, minKeys)
	}

	removed := n.children[childIdx].remove(key, minKeys)
	if removed {
		n.count--
	}
	return removed
}

func (n *node) replaceWithLeftMax(keyIdx, minKeys int) {
	key := n.leftChild(keyIdx).removeMax(minKeys)
	n.keys[keyIdx] = key
}

func (n *node) removeMax(minKeys int) (maxKey key) {
	if n.isLeaf() {
		lastKeyIdx := n.size() - 1
		maxKey = n.keys[lastKeyIdx]
		n.removeAt(lastKeyIdx)
		n.count--
		return maxKey
	}

	if n.lastChild().size() <= minKeys {
		lastChildIdx := n.numOfChildren() - 1
		n.fill(lastChildIdx, minKeys)
	}

	maxKey = n.lastChild().removeMax(minKeys)
	n.count--
	return maxKey
}

func (n *node) replaceWithRightMin(keyIdx, minKeys int) {
	key := n.rightChild(keyIdx).removeMin(minKeys)
	n.keys[keyIdx] = key
}

func (n *node) removeMin(minKeys int) (minKey key) {
	if n.isLeaf() {
		minKey = n.keys[0]
		n.removeAt(0)
		n.count--
		return minKey
	}

	if n.firstChild().size() <= minKeys {
		n.fill(0, minKeys)
	}

	minKey = n.firstChild().removeMin(minKeys)
	n.count--
	return minKey
}

func (n *node) fill(childIdx, minKeys int) (updatedIdx int) {
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
	parentKey := n.keys[childIdx-1]
	leftSibling := n.children[childIdx-1]
	leftLastKey := leftSibling.keys[leftSibling.size()-1]

	child := n.children[childIdx]
	child.insertAt(0, parentKey)

	n.updateAt(childIdx-1, leftLastKey)
	leftSibling.removeAt(leftSibling.size() - 1)

	if !leftSibling.isLeaf() {
		child.insertChildAt(0, leftSibling.lastChild())
		leftSibling.removeLastChild()
	}

	leftSibling.refreshCount()
	child.refreshCount()
	n.refreshCount()
}

func (n *node) borrowFromRight(childIdx int) {
	parentKey := n.keys[childIdx]
	rightSibling := n.children[childIdx+1]
	rightFirstKey := rightSibling.keys[0]

	child := n.children[childIdx]
	child.insertAt(child.size(), parentKey)

	n.updateAt(childIdx, rightFirstKey)
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
	left := n.children[keyIdx]
	right := n.children[keyIdx+1]

	left.keys = append(left.keys, parentKey)
	left.keys = append(left.keys, right.keys...)

	if !right.isLeaf() {
		left.children = append(left.children, right.children...)
	}

	n.removeAt(keyIdx)
	n.removeChildAt(keyIdx + 1)
	left.refreshCount()
	n.refreshCount()
}

func (n *node) getByIndex(index int) key {
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
			return n.keys[i]
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
		key := n.keys[i]
		if start != nil && key.Less(start) {
			continue
		}
		if end != nil && !key.Less(end) {
			return false
		}
		if cb(key) {
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
		key := n.keys[keyIdx]
		if end != nil && end.Less(key) {
			continue
		}
		if start != nil && !start.Less(key) {
			return false
		}
		if cb(key) {
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
		if visitKeyByOffset(n.keys[i], offset, limit, seen, visited, cb) {
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
		if visitKeyByOffset(n.keys[i], offset, limit, seen, visited, cb) {
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
	if cb(key) {
		return true
	}
	*visited++
	return false
}
