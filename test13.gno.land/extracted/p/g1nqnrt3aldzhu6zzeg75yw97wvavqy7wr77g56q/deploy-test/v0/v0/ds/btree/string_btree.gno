package btree

type StringIterCbFn func(key string, value any) bool

type StringBTree struct {
	tree *bTree
}

func NewStringBTree(degree int) *StringBTree {
	return &StringBTree{tree: newBTree(degree)}
}

func (t *StringBTree) Size() int {
	return t.tree.Size()
}

func (t *StringBTree) Set(key string, value any) bool {
	return t.tree.Set(stringKey(key), value)
}

func (t *StringBTree) Get(key string) (any, bool) {
	return t.tree.Get(stringKey(key))
}

func (t *StringBTree) Has(key string) bool {
	return t.tree.Has(stringKey(key))
}

func (t *StringBTree) Remove(key string) (any, bool) {
	return t.tree.Remove(stringKey(key))
}

func (t *StringBTree) GetByIndex(index int) (string, any) {
	key, value := t.tree.GetByIndex(index)
	return string(key.(stringKey)), value
}

func (t *StringBTree) Iterate(start, end *string, cb StringIterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = stringKey(*start)
	}

	var endKey key
	if end != nil {
		endKey = stringKey(*end)
	}
	return t.tree.Iterate(startKey, endKey, func(key key, value any) bool {
		return cb(string(key.(stringKey)), value)
	})
}

func (t *StringBTree) ReverseIterate(start, end *string, cb StringIterCbFn) bool {
	var startKey key
	if start != nil {
		startKey = stringKey(*start)
	}

	var endKey key
	if end != nil {
		endKey = stringKey(*end)
	}
	return t.tree.ReverseIterate(startKey, endKey, func(key key, value any) bool {
		return cb(string(key.(stringKey)), value)
	})
}

func (t *StringBTree) IterateByOffset(offset int, count int, cb StringIterCbFn) bool {
	return t.tree.IterateByOffset(offset, count, func(key key, value any) bool {
		return cb(string(key.(stringKey)), value)
	})
}

func (t *StringBTree) ReverseIterateByOffset(offset int, count int, cb StringIterCbFn) bool {
	return t.tree.ReverseIterateByOffset(offset, count, func(key key, value any) bool {
		return cb(string(key.(stringKey)), value)
	})
}
