package btreeset

type Uint32IterCbFn func(key uint32) bool

type Uint32BTreeSet struct {
	tree *bTreeSet
}

func NewUint32BTreeSet(degree int) *Uint32BTreeSet {
	return &Uint32BTreeSet{tree: newBTreeSet(degree)}
}

func (t *Uint32BTreeSet) Size() int {
	return t.tree.Size()
}

func (t *Uint32BTreeSet) Set(key uint32) bool {
	return t.tree.Set(uint32Key(key))
}

func (t *Uint32BTreeSet) Has(key uint32) bool {
	return t.tree.Has(uint32Key(key))
}

func (t *Uint32BTreeSet) Remove(key uint32) bool {
	return t.tree.Remove(uint32Key(key))
}

func (t *Uint32BTreeSet) GetByIndex(index int) uint32 {
	key := t.tree.GetByIndex(index)
	return uint32(key.(uint32Key))
}

func (t *Uint32BTreeSet) Iterate(start, end *uint32, cb Uint32IterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = uint32Key(*start)
	}

	var endKey key
	if end != nil {
		endKey = uint32Key(*end)
	}
	return t.tree.Iterate(startKey, endKey, func(key key) bool {
		return cb(uint32(key.(uint32Key)))
	})
}

func (t *Uint32BTreeSet) ReverseIterate(start, end *uint32, cb Uint32IterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = uint32Key(*start)
	}

	var endKey key
	if end != nil {
		endKey = uint32Key(*end)
	}
	return t.tree.ReverseIterate(startKey, endKey, func(key key) bool {
		return cb(uint32(key.(uint32Key)))
	})
}

func (t *Uint32BTreeSet) IterateByOffset(offset int, count int, cb Uint32IterCbFn) bool {
	return t.tree.IterateByOffset(offset, count, func(key key) bool {
		return cb(uint32(key.(uint32Key)))
	})
}

func (t *Uint32BTreeSet) ReverseIterateByOffset(offset int, count int, cb Uint32IterCbFn) bool {
	return t.tree.ReverseIterateByOffset(offset, count, func(key key) bool {
		return cb(uint32(key.(uint32Key)))
	})
}
