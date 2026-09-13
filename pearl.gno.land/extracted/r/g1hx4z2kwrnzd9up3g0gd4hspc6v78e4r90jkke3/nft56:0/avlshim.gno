package nft56

import "gno.land/p/nt/avl/v0"

// avlGet is the ONE place where this package touches avl.Tree.Get.
//
// The avl/v0 published on gno.land returns (value, exists); the one
// shipped with the pearl testnet's GNOROOT returns a single value. Every
// other line of this package is identical on both networks, so the whole
// difference is isolated here instead of being spread over every call
// site. Switch it with: python3 scripts/avl-shim.py <pearl|mainnet>
//
// AVL-VARIANT: pearl
func avlGet(t *avl.Tree, key string) any {
	return t.Get(key)
}
