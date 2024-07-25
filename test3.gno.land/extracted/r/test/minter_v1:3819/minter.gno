package minter

import (
	"std"

	"gno.land/p/demo/avl"
)

var (
	denoms = avl.NewMutTree() // id -> *minter
)

func Mint(addr std.Address, denom string, amount int64) {
	caller := std.GetOrigCaller()
	if denoms.Has(denom) {
		data, _ := denoms.Get(denom)
		minter := data.(std.Address)
		if minter != caller {
			panic("not minter")
		}
	} else {
		denoms.Set(denom, caller)
	}

	issuer := std.GetBanker(std.BankerTypeRealmIssue)
	issuer.IssueCoin(addr, denom, amount)
}
