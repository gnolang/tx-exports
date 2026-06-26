package btreeset

type bTreeSet struct {
	degree    int
	size      int
	root      *node
	iterating int
}

func newBTreeSet(degree int) *bTreeSet {
	if degree <= 1 {
		panic("degree must be greater than 1")
	}
	return &bTreeSet{degree: degree}
}

func (t *bTreeSet) maxKeys() int { return t.degree*2 - 1 }
func (t *bTreeSet) minKeys() int { return t.degree - 1 }
func (t *bTreeSet) Size() int    { return t.size }

func (t *bTreeSet) Set(key key) (existed bool) {
	t.assertNotIterating()

	maxKeys := t.degree*2 - 1
	if t.root == nil {
		t.root = newNodeWithEntry(key, maxKeys)
		t.size = 1
		return false
	}

	if t.root.has(key) {
		return true
	}

	if t.root.size() >= maxKeys {
		t.splitRoot(maxKeys, t.root.lastKey().Less(key))
	}

	inserted := t.root.setNonFull(key, maxKeys)
	if inserted {
		t.size++
	}

	return !inserted
}

func (t *bTreeSet) splitRoot(maxKeys int, appendSplit bool) {
	newRoot := newNode(maxKeys)
	newRoot.children = []*node{t.root}
	newRoot.split(0, maxKeys, appendSplit)
	t.root = newRoot
}

func (t *bTreeSet) Has(key key) bool {
	if t.root == nil {
		return false
	}

	return t.root.has(key)
}

func (t *bTreeSet) Remove(key key) (removed bool) {
	t.assertNotIterating()

	if t.root == nil {
		return false
	}

	removed = t.root.remove(key, t.minKeys())
	if !removed {
		return false
	}

	t.size--

	if t.root.size() == 0 && !t.root.isLeaf() {
		t.root = t.root.firstChild()
	} else if t.root.size() == 0 {
		t.root = nil
	}

	return true
}

func (t *bTreeSet) GetByIndex(index int) key {
	if t.root == nil || index < 0 || index >= t.size {
		panic("GetByIndex asked for invalid index")
	}
	return t.root.getByIndex(index)
}

// Iterate visits keys in ascending order over [start, end).
// A nil start means no lower bound, and a nil end means no upper bound.
func (t *bTreeSet) Iterate(start, end key, cb iterCbFn) bool {
	t.assertNotIteratingForIteration()
	if t.root == nil {
		return false
	}
	t.beginIteration()
	defer t.endIteration()
	return t.root.iterate(start, end, cb)
}

// ReverseIterate visits keys in descending order over (start, end].
// A nil start means no lower bound, and a nil end means no upper bound.
func (t *bTreeSet) ReverseIterate(start, end key, cb iterCbFn) bool {
	t.assertNotIteratingForIteration()
	if t.root == nil {
		return false
	}
	t.beginIteration()
	defer t.endIteration()
	return t.root.reverseIterate(start, end, cb)
}

func (t *bTreeSet) IterateByOffset(offset int, count int, cb iterCbFn) bool {
	t.assertNotIteratingForIteration()
	if t.root == nil || offset < 0 || offset >= t.size || count <= 0 {
		return false
	}
	seen := 0
	visited := 0
	t.beginIteration()
	defer t.endIteration()
	return t.root.iterateByOffset(offset, count, false, &seen, &visited, cb)
}

func (t *bTreeSet) ReverseIterateByOffset(offset int, count int, cb iterCbFn) bool {
	t.assertNotIteratingForIteration()
	if t.root == nil || offset < 0 || offset >= t.size || count <= 0 {
		return false
	}
	seen := 0
	visited := 0
	t.beginIteration()
	defer t.endIteration()
	return t.root.iterateByOffset(offset, count, true, &seen, &visited, cb)
}

func (t *bTreeSet) beginIteration() {
	t.iterating++
}

func (t *bTreeSet) endIteration() {
	t.iterating--
}

func (t *bTreeSet) assertNotIterating() {
	if t.iterating > 0 {
		panic("btreeset mutation during iteration")
	}
}

func (t *bTreeSet) assertNotIteratingForIteration() {
	if t.iterating > 0 {
		panic("btreeset iteration during iteration")
	}
}
