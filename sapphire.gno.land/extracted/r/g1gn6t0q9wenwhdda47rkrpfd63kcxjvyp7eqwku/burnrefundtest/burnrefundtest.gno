package burnrefundtest

import (
	"gno.land/p/nt/avl/v0"
)

// Test realm for one question: can a Burn that deletes EXACTLY what
// Mint wrote -- nothing more, nothing less, no bookkeeping record left
// behind -- get a 100% storage-fee refund? tokens is the only state
// this realm has.
var tokens avl.Tree

// Mint stores data under tid. A real NFT stores name/image/attributes
// across multiple fields; one string is enough here since the storage
// deposit mechanism only cares about total bytes written.
func Mint(cur realm, tid string, data string) {
	tokens.Set(tid, data)
}

// Burn removes ONLY what Mint wrote for tid. No burn record, no
// history, no permanent bookkeeping -- the control case for whether
// 100% refund is achievable at all.
func Burn(cur realm, tid string) {
	tokens.Remove(tid)
}

func Has(tid string) bool {
	return tokens.Has(tid)
}
