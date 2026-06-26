package btreeset

type StringIterCbFn func(key string) bool

type StringBTreeSet struct {
	tree *bTreeSet
}

func NewStringBTreeSet(degree int) *StringBTreeSet {
	return &StringBTreeSet{tree: newBTreeSet(degree)}
}

func (t *StringBTreeSet) Size() int {
	return t.tree.Size()
}

func (t *StringBTreeSet) Set(key string) bool {
	return t.tree.Set(stringKey(key))
}

func (t *StringBTreeSet) Has(key string) bool {
	return t.tree.Has(stringKey(key))
}

func (t *StringBTreeSet) Remove(key string) bool {
	return t.tree.Remove(stringKey(key))
}

func (t *StringBTreeSet) GetByIndex(index int) string {
	key := t.tree.GetByIndex(index)
	return string(key.(stringKey))
}

func (t *StringBTreeSet) Iterate(start, end *string, cb StringIterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = stringKey(*start)
	}

	var endKey key
	if end != nil {
		endKey = stringKey(*end)
	}
	return t.tree.Iterate(startKey, endKey, func(key key) bool {
		return cb(string(key.(stringKey)))
	})
}

func (t *StringBTreeSet) ReverseIterate(start, end *string, cb StringIterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = stringKey(*start)
	}

	var endKey key
	if end != nil {
		endKey = stringKey(*end)
	}
	return t.tree.ReverseIterate(startKey, endKey, func(key key) bool {
		return cb(string(key.(stringKey)))
	})
}

func (t *StringBTreeSet) IterateByOffset(offset int, count int, cb StringIterCbFn) bool {
	return t.tree.IterateByOffset(offset, count, func(key key) bool {
		return cb(string(key.(stringKey)))
	})
}

func (t *StringBTreeSet) ReverseIterateByOffset(offset int, count int, cb StringIterCbFn) bool {
	return t.tree.ReverseIterateByOffset(offset, count, func(key key) bool {
		return cb(string(key.(stringKey)))
	})
}
