package btreeset

type Uint64IterCbFn func(key uint64) bool

type Uint64BTreeSet struct {
	tree *bTreeSet
}

func NewUint64BTreeSet(degree int) *Uint64BTreeSet {
	return &Uint64BTreeSet{tree: newBTreeSet(degree)}
}

func (t *Uint64BTreeSet) Size() int {
	return t.tree.Size()
}

func (t *Uint64BTreeSet) Set(key uint64) bool {
	return t.tree.Set(uint64Key(key))
}

func (t *Uint64BTreeSet) Has(key uint64) bool {
	return t.tree.Has(uint64Key(key))
}

func (t *Uint64BTreeSet) Remove(key uint64) bool {
	return t.tree.Remove(uint64Key(key))
}

func (t *Uint64BTreeSet) GetByIndex(index int) uint64 {
	key := t.tree.GetByIndex(index)
	return uint64(key.(uint64Key))
}

func (t *Uint64BTreeSet) Iterate(start, end *uint64, cb Uint64IterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = uint64Key(*start)
	}

	var endKey key
	if end != nil {
		endKey = uint64Key(*end)
	}
	return t.tree.Iterate(startKey, endKey, func(key key) bool {
		return cb(uint64(key.(uint64Key)))
	})
}

func (t *Uint64BTreeSet) ReverseIterate(start, end *uint64, cb Uint64IterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = uint64Key(*start)
	}

	var endKey key
	if end != nil {
		endKey = uint64Key(*end)
	}
	return t.tree.ReverseIterate(startKey, endKey, func(key key) bool {
		return cb(uint64(key.(uint64Key)))
	})
}

func (t *Uint64BTreeSet) IterateByOffset(offset int, count int, cb Uint64IterCbFn) bool {
	return t.tree.IterateByOffset(offset, count, func(key key) bool {
		return cb(uint64(key.(uint64Key)))
	})
}

func (t *Uint64BTreeSet) ReverseIterateByOffset(offset int, count int, cb Uint64IterCbFn) bool {
	return t.tree.ReverseIterateByOffset(offset, count, func(key key) bool {
		return cb(uint64(key.(uint64Key)))
	})
}
