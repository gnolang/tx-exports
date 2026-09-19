// Package trie provides a simple prefix-tree (trie) for storing key-value data
// in Gno realms.
//
// Keys are strings ordered lexicographically by their raw bytes and values can
// be of any type. Tree implements the avl.ITree interface from
// `gno.land/p/nt/avl`, so it can be used as an alternative to an AVL tree.
package trie
