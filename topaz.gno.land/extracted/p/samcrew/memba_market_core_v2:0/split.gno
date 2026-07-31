package memba_market_core_v2

// SplitProceedsBPS computes the three-way split of a sale price into platform fee,
// creator royalty, and seller proceeds, with the platform fee in basis points
// supplied by the caller (read per-lane from memba_market_config) instead of the
// frozen FeeBPS constant. This is the spine that lets every engine charge a
// DAO-tunable, per-lane fee while sharing one audited money-math implementation.
//
// `feeBPS` is validated to [0, MaxFeeBPS] — the 5% ceiling the DAO can never exceed
// — so a misconfigured or compromised config realm cannot make an engine overcharge.
// `royaltyAmount` is the actual amount from RoyaltyInfo (NOT bps); floored at 0 and
// clamped to MaxRoyaltyBPS of price. A zero fee is permitted (feeBPS may legitimately
// be 0, or round to 0 on a small price); engines that must guarantee non-zero protocol
// revenue (e.g. fungible OTC partial fills) enforce a per-fill minimum notional at
// their call site — that is an engine concern, not pure money-math.
func SplitProceedsBPS(price, feeBPS, royaltyAmount int64) (fee, royalty, seller int64) {
	if price < MinPrice {
		panic("price below minimum")
	}
	if price > MaxPrice {
		panic("price above maximum")
	}
	if feeBPS < 0 {
		panic("feeBPS negative")
	}
	if feeBPS > MaxFeeBPS {
		panic("feeBPS above maximum")
	}
	fee = price * feeBPS / 10000
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

// SplitProceeds is the frozen FeeBPS (2.0%) conformance path, kept behaviorally
// identical to memba_nft_market_v3's splitProceeds. It delegates to SplitProceedsBPS
// with the default FeeBPS so existing engines are unchanged.
func SplitProceeds(price, royaltyAmount int64) (fee, royalty, seller int64) {
	return SplitProceedsBPS(price, FeeBPS, royaltyAmount)
}
