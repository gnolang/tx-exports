package burnrefundtest2

import (
	"strings"

	"gno.land/p/nt/avl/v0"
)

var tokens avl.Tree

func Mint(cur realm, tid string, length int) {
	tokens.Set(tid, strings.Repeat("x", length))
}

func Burn(cur realm, tid string) {
	tokens.Remove(tid)
}

func Has(tid string) bool {
	return tokens.Has(tid)
}
