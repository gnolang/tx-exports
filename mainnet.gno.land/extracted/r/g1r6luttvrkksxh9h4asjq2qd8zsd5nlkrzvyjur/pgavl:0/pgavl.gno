package pgavl
import "gno.land/p/nt/avl/v0"
var t avl.Tree
func Set(cur realm, k string) { t.Set(k, 1) }
func Render(path string) string { return "avl" }
