package btree

type Uint32IterCbFn func(key uint32, value any) bool

type Uint32BTree struct {
	tree *bTree
}

func NewUint32BTree(degree int) *Uint32BTree {
	return &Uint32BTree{tree: newBTree(degree)}
}

func (t *Uint32BTree) Size() int {
	return t.tree.Size()
}

func (t *Uint32BTree) Set(key uint32, value any) bool {
	return t.tree.Set(uint32Key(key), value)
}

func (t *Uint32BTree) Get(key uint32) (any, bool) {
	return t.tree.Get(uint32Key(key))
}

func (t *Uint32BTree) Has(key uint32) bool {
	return t.tree.Has(uint32Key(key))
}

func (t *Uint32BTree) Remove(key uint32) (any, bool) {
	return t.tree.Remove(uint32Key(key))
}

func (t *Uint32BTree) GetByIndex(index int) (uint32, any) {
	key, value := t.tree.GetByIndex(index)
	return uint32(key.(uint32Key)), value
}

func (t *Uint32BTree) Iterate(start, end *uint32, cb Uint32IterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = uint32Key(*start)
	}

	var endKey key
	if end != nil {
		endKey = uint32Key(*end)
	}
	return t.tree.Iterate(startKey, endKey, func(key key, value any) bool {
		return cb(uint32(key.(uint32Key)), value)
	})
}

func (t *Uint32BTree) ReverseIterate(start, end *uint32, cb Uint32IterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = uint32Key(*start)
	}

	var endKey key
	if end != nil {
		endKey = uint32Key(*end)
	}
	return t.tree.ReverseIterate(startKey, endKey, func(key key, value any) bool {
		return cb(uint32(key.(uint32Key)), value)
	})
}

func (t *Uint32BTree) IterateByOffset(offset int, count int, cb Uint32IterCbFn) bool {
	return t.tree.IterateByOffset(offset, count, func(key key, value any) bool {
		return cb(uint32(key.(uint32Key)), value)
	})
}

func (t *Uint32BTree) ReverseIterateByOffset(offset int, count int, cb Uint32IterCbFn) bool {
	return t.tree.ReverseIterateByOffset(offset, count, func(key key, value any) bool {
		return cb(uint32(key.(uint32Key)), value)
	})
}
