package btree

func equalKey(a, b key) bool {
	return !a.Less(b) && !b.Less(a)
}
