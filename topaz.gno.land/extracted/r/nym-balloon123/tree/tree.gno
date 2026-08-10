package tree

import "gno.land/p/nt/avl/v0"

var tree avl.Tree

func Set(key string, value string) {
	tree.Set(key, value)
}

func Get(key string) string {
	value := tree.Get(key)
	if value == nil {
		return ""
	}
	return value.(string)
}

func Has(key string) bool {
	return tree.Has(key)
}

func Size() int {
	return tree.Size()
}

func Render(path string) string {
	return "AVL Tree size: " + string(Size())
}
