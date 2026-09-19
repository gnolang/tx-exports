# Trie Package

Package implements a simple prefix-tree (trie) for Gno realms, keyed by
`string` with values of any type.

`Tree` implements the [`avl.ITree`](https://gno.land/p/nt/avl/v0$source&file=tree.gno)
interface from `gno.land/p/nt/avl`, so it can be used as a drop-in alternative
to an AVL tree.

Repository can be found at [jeronimoalbi/gnome](https://github.com/jeronimoalbi/gnome),
as part of `jeronimoalbi`'s Gno smart contracts monorepo.

## Usage

[embedmd]:# (filetests/readme_filetest.gno go)
```go
package main

import "gno.land/p/jeronimoalbi/trie"

func main() {
	tree := trie.NewTree()
	tree.Set("apple", 1)
	tree.Set("app", 2)
	tree.Set("banana", 3)

	// Get value for app
	v := tree.Get("app")
	println(v)

	// Iterate keys in lexicographic order: app, apple, banana.
	tree.Iterate("", "", func(key string, value any) bool {
		println(key, value)
		return false
	})
}

// Output:
// 2
// app 2
// apple 1
// banana 3
```
