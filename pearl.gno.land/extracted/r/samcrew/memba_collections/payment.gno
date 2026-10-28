package memba_collections

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/r/demo/defi/grc20reg"
)

func chainHeight() int64 { return runtime.ChainHeight() }

func selfAddr() address { return unsafe.CurrentRealm().Address() }

// denomKey normalizes a payDenom to its proceeds-ledger key (native → "ugnot").
func denomKey(d string) string {
	if isNativeDenom(d) {
		return "ugnot"
	}
	return d
}

// isNativeDenom reports whether a payDenom string means native ugnot.
func isNativeDenom(d string) bool { return d == "" || d == "ugnot" }

// sumDenom totals the coins of a single denom in a coin set.
func sumDenom(coins chain.Coins, denom string) int64 {
	total := int64(0)
	for _, c := range coins {
		if c.Denom == denom {
			total += c.Amount
		}
	}
	return total
}

// sendNative sends ugnot from the realm to `to` via a realm-send banker.
func sendNative(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(unsafe.CurrentRealm().Address(), to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

// grc20Teller resolves a registered token by its grc20reg key and returns a
// RealmTeller (the realm is the spender — frozen B-1). Panics if unknown.
func grc20Teller(cur realm, denom string) grc20.Teller {
	tok := grc20reg.Get(denom)
	if tok == nil {
		panic("unknown grc20 denom: " + denom)
	}
	return tok.RealmTeller(0, cur)
}
