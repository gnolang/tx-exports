package verdict4

import "chain/runtime"

func Settle(cur realm, marketID uint64) {
	requireDirectUserCall(0, cur)

	market, ok := marketByID(marketID)
	if !ok {
		panic("market not found")
	}
	if market.Status != MarketOpen {
		panic("market already settled")
	}
	if runtime.ChainHeight() < market.CloseHeight {
		panic("settlement not ready")
	}

	outcome := resolveOutcome(market)
	pool := totalPool(market)

	market.Status = MarketResolved
	market.Outcome = outcome
	market.RemainingClaimable = pool
	market.RemainingWinningShares = winningPoolFor(market, outcome)

	markets.Set(marketKey(marketID), market)
}
