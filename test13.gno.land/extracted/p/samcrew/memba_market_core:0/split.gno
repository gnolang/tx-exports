package memba_market_core

// SplitProceeds computes the three-way split of a sale price into platform fee,
// creator royalty, and seller proceeds. `royaltyAmount` is the actual amount from
// the collection's RoyaltyInfo (NOT bps); it is floored at 0 and clamped to
// MaxRoyaltyBPS of price (defense-in-depth). Identical to memba_nft_market_v3's
// splitProceeds — the conformance reference for every engine.
func SplitProceeds(price, royaltyAmount int64) (fee, royalty, seller int64) {
	if price < MinPrice {
		panic("price below minimum")
	}
	if price > MaxPrice {
		panic("price above maximum")
	}
	fee = price * FeeBPS / 10000
	royalty = royaltyAmount
	if royalty < 0 {
		royalty = 0
	}
	maxRoy := price * MaxRoyaltyBPS / 10000
	if royalty > maxRoy {
		royalty = maxRoy
	}
	if fee+royalty >= price {
		panic("fee plus royalty exceeds price")
	}
	seller = price - fee - royalty
	if seller <= 0 {
		panic("seller amount not positive")
	}
	return
}
