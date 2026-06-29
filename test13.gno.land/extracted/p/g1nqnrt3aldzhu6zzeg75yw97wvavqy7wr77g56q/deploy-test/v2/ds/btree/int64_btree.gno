package btree

type Int64IterCbFn func(key int64, value any) bool

type Int64BTree struct {
	tree *bTree
}

func NewInt64BTree(degree int) *Int64BTree {
	return &Int64BTree{tree: newBTree(degree)}
}

func (t *Int64BTree) Size() int {
	return t.tree.Size()
}

func (t *Int64BTree) Set(key int64, value any) bool {
	return t.tree.Set(int64Key(key), value)
}

func (t *Int64BTree) Get(key int64) (any, bool) {
	return t.tree.Get(int64Key(key))
}

func (t *Int64BTree) Has(key int64) bool {
	return t.tree.Has(int64Key(key))
}

func (t *Int64BTree) Remove(key int64) (any, bool) {
	return t.tree.Remove(int64Key(key))
}

func (t *Int64BTree) GetByIndex(index int) (int64, any) {
	key, value := t.tree.GetByIndex(index)
	return int64(key.(int64Key)), value
}

func (t *Int64BTree) Iterate(start, end *int64, cb Int64IterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = int64Key(*start)
	}

	var endKey key
	if end != nil {
		endKey = int64Key(*end)
	}
	return t.tree.Iterate(startKey, endKey, func(key key, value any) bool {
		return cb(int64(key.(int64Key)), value)
	})
}

func (t *Int64BTree) ReverseIterate(start, end *int64, cb Int64IterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = int64Key(*start)
	}

	var endKey key
	if end != nil {
		endKey = int64Key(*end)
	}
	return t.tree.ReverseIterate(startKey, endKey, func(key key, value any) bool {
		return cb(int64(key.(int64Key)), value)
	})
}

func (t *Int64BTree) IterateByOffset(offset int, count int, cb Int64IterCbFn) bool {
	return t.tree.IterateByOffset(offset, count, func(key key, value any) bool {
		return cb(int64(key.(int64Key)), value)
	})
}

func (t *Int64BTree) ReverseIterateByOffset(offset int, count int, cb Int64IterCbFn) bool {
	return t.tree.ReverseIterateByOffset(offset, count, func(key key, value any) bool {
		return cb(int64(key.(int64Key)), value)
	})
}
