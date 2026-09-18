package padv2

// tryListOnZdex — stub until Zdex hub allows farm/realm CreatePool.
// Live Pearl/mainnet: CreatePool is EOA-only + requireListed.
// Pad path today:
//  1) ReleaseListSeed(id) — WUGNOT + minted PoolToken → creator
//  2) EOA: optional wugnot.Withdraw → Approve(zdex RealmAddr) → CreatePool
//  3) ConfirmZdexList(id, poolId) — mark ListVenue=zdex
//
// Pearl hub: gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/zdex/v3
// CreatePool(cur, tokenKey, symbol, amountU, amountT, feeBps) string
func tryListOnZdex(cur realm, l *Launch, raisedUgnot, liqTokens int64) bool {
	_ = cur
	_ = raisedUgnot
	_ = liqTokens
	if testForceZdexList && l != nil {
		l.GnoswapListed = true // compat "listed" flag used by UI
		l.GnoswapPoolPath = "ugnot|" + l.Symbol
		l.GnoswapPositionID = 0
		l.LiqWugnotUsed = raisedUgnot
		l.GnoswapNote = "listed (test force zdex)"
		l.ListVenue = VenueZdex
		return true
	}
	if l != nil {
		if l.ListSeedReleased {
			l.GnoswapNote =
				"zdex: seed released — EOA CreatePool then ConfirmZdexList(id, ugnot|SYMBOL); PreferredVenue=" +
					l.PreferredVenue
		} else {
			l.GnoswapNote =
				"zdex: ReleaseListSeed → EOA CreatePool (WUGNOT Withdraw + Approve RealmAddr) → ConfirmZdexList; PreferredVenue=" +
					l.PreferredVenue
		}
	}
	return false
}
