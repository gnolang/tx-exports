package btree

type Uint64IterCbFn func(key uint64, value any) bool

type Uint64BTree struct {
	tree *bTree
}

func NewUint64BTree(degree int) *Uint64BTree {
	return &Uint64BTree{tree: newBTree(degree)}
}

func (t *Uint64BTree) Size() int {
	return t.tree.Size()
}

func (t *Uint64BTree) Set(key uint64, value any) bool {
	return t.tree.Set(uint64Key(key), value)
}

func (t *Uint64BTree) Get(key uint64) (any, bool) {
	return t.tree.Get(uint64Key(key))
}

func (t *Uint64BTree) Has(key uint64) bool {
	return t.tree.Has(uint64Key(key))
}

func (t *Uint64BTree) Remove(key uint64) (any, bool) {
	return t.tree.Remove(uint64Key(key))
}

func (t *Uint64BTree) GetByIndex(index int) (uint64, any) {
	key, value := t.tree.GetByIndex(index)
	return uint64(key.(uint64Key)), value
}

func (t *Uint64BTree) Iterate(start, end *uint64, cb Uint64IterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = uint64Key(*start)
	}

	var endKey key
	if end != nil {
		endKey = uint64Key(*end)
	}
	return t.tree.Iterate(startKey, endKey, func(key key, value any) bool {
		return cb(uint64(key.(uint64Key)), value)
	})
}

func (t *Uint64BTree) ReverseIterate(start, end *uint64, cb Uint64IterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = uint64Key(*start)
	}

	var endKey key
	if end != nil {
		endKey = uint64Key(*end)
	}
	return t.tree.ReverseIterate(startKey, endKey, func(key key, value any) bool {
		return cb(uint64(key.(uint64Key)), value)
	})
}

func (t *Uint64BTree) IterateByOffset(offset int, count int, cb Uint64IterCbFn) bool {
	return t.tree.IterateByOffset(offset, count, func(key key, value any) bool {
		return cb(uint64(key.(uint64Key)), value)
	})
}

func (t *Uint64BTree) ReverseIterateByOffset(offset int, count int, cb Uint64IterCbFn) bool {
	return t.tree.ReverseIterateByOffset(offset, count, func(key key, value any) bool {
		return cb(uint64(key.(uint64Key)), value)
	})
}
