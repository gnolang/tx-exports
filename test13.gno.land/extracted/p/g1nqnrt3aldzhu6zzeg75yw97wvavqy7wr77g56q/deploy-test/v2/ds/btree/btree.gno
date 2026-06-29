package btree

type bTree struct {
	degree    int
	size      int
	root      *node
	iterating int
}

func newBTree(degree int) *bTree {
	if degree <= 1 {
		panic("degree must be greater than 1")
	}
	return &bTree{degree: degree}
}

func (t *bTree) maxKeys() int { return t.degree*2 - 1 }
func (t *bTree) minKeys() int { return t.degree - 1 }
func (t *bTree) Size() int    { return t.size }

// Set inserts or updates key/value. It returns true when key already existed.
func (t *bTree) Set(key key, value any) (updated bool) {
	t.assertNotIterating()

	maxKeys := t.degree*2 - 1
	if t.root == nil {
		t.root = newNodeWithEntry(key, value, maxKeys)
		t.size = 1
		return false
	}

	if t.root.size() >= maxKeys {
		if t.root.update(key, value) {
			return true
		}
		t.splitRoot(maxKeys, t.root.lastKey().Less(key))
	}

	inserted := t.root.setNonFull(key, value, maxKeys)
	if inserted {
		t.size++
	}
	return !inserted
}

func (t *bTree) splitRoot(maxKeys int, appendSplit bool) {
	newRoot := newNode(maxKeys)
	newRoot.children = []*node{t.root}
	newRoot.split(0, maxKeys, appendSplit)
	t.root = newRoot
}

func (t *bTree) Get(key key) (any, bool) {
	if t.root == nil {
		return nil, false
	}
	return t.root.get(key)
}

func (t *bTree) Has(key key) bool {
	_, ok := t.Get(key)
	return ok
}

func (t *bTree) Remove(key key) (any, bool) {
	t.assertNotIterating()

	if t.root == nil {
		return nil, false
	}

	v, removed := t.root.remove(key, t.minKeys())
	if !removed {
		return nil, false
	}

	t.size--

	if t.root.size() == 0 && !t.root.isLeaf() {
		t.root = t.root.firstChild()
	} else if t.root.size() == 0 {
		t.root = nil
	}
	return v, true
}

func (t *bTree) GetByIndex(index int) (key, any) {
	if t.root == nil || index < 0 || index >= t.size {
		panic("GetByIndex asked for invalid index")
	}
	return t.root.getByIndex(index)
}

// Iterate visits keys in ascending order within [start, end).
// A nil start means no lower bound, and a nil end means no upper bound.
func (t *bTree) Iterate(start, end key, cb iterCbFn) bool {
	t.assertNotIteratingForIteration()
	if t.root == nil {
		return false
	}
	t.beginIteration()
	defer t.endIteration()
	return t.root.iterate(start, end, cb)
}

// ReverseIterate visits keys in descending order over [start, end].
// A nil start means no lower bound, and a nil end means no upper bound.
func (t *bTree) ReverseIterate(start, end key, cb iterCbFn) bool {
	t.assertNotIteratingForIteration()
	if t.root == nil {
		return false
	}
	t.beginIteration()
	defer t.endIteration()
	return t.root.reverseIterate(start, end, cb)
}

func (t *bTree) IterateByOffset(offset int, count int, cb iterCbFn) bool {
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

func (t *bTree) ReverseIterateByOffset(offset int, count int, cb iterCbFn) bool {
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

func (t *bTree) beginIteration() {
	t.iterating++
}

func (t *bTree) endIteration() {
	t.iterating--
}

func (t *bTree) assertNotIterating() {
	if t.iterating > 0 {
		panic("btree mutation during iteration")
	}
}

func (t *bTree) assertNotIteratingForIteration() {
	if t.iterating > 0 {
		panic("btree iteration during iteration")
	}
}
