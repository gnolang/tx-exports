package memba_nft_v2

import "chain"

// ── Group 4: market registry ──────────────────────────────────────────────────

func RegisterMarket(cur realm, marketAddr address) {
	assertAdmin()
	registeredMarkets.Set(marketAddr.String(), true)
	chain.Emit("MarketRegistered", "market", marketAddr.String())
}

func UnregisterMarket(cur realm, marketAddr address) {
	assertAdmin()
	registeredMarkets.Remove(marketAddr.String())
	chain.Emit("MarketUnregistered", "market", marketAddr.String())
}

func isRegisteredMarket(a address) bool {
	v, ok := registeredMarkets.Get(a.String())
	return ok && v.(bool)
}
