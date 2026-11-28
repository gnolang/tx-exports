package verdict2

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"math/overflow"

	verdict "gno.land/p/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict"
)

func Claim(cur realm, marketID uint64) {
	requireDirectUserCall(0, cur)
	runtime.AssertOriginCall()
	claimFor(cur, marketID, cur.Previous().Address())
}

func claimFor(cur realm, marketID uint64, account address) int64 {
	market, ok := marketByID(marketID)
	if !ok {
		panic("market not found")
	}
	if market.Status != MarketResolved {
		panic("market not settled")
	}

	position, ok := positionByIDAndAddress(marketID, account)
	if !ok {
		panic("no position")
	}
	if position.Claimed {
		panic("already claimed")
	}

	stake, ok := overflow.Add64(position.YesStake, position.NoStake)
	if !ok {
		panic("position overflow")
	}
	if stake <= 0 {
		panic("claim not available")
	}

	payout := payoutForPosition(market, position)
	if payout <= 0 || payout > market.RemainingClaimable {
		panic("claim not available")
	}

	// Effects happen before the token transfer.
	position.Claimed = true
	market.RemainingClaimable -= payout
	if market.Outcome != verdict.OutcomeInvalid {
		shares := position.NoStake
		if market.Outcome == verdict.OutcomeYes {
			shares = position.YesStake
		}
		if shares > market.RemainingWinningShares {
			panic("remaining shares underflow")
		}
		market.RemainingWinningShares -= shares
	}
	positions.Set(positionKey(marketID, account), position)
	markets.Set(marketKey(marketID), market)
	recordRealizedNet(account, payout-stake)

	// Interaction: pull payment from the realm pool.
	coins := chain.NewCoins(chain.NewCoin("ugnot", payout))
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), account, coins)
	return payout
}

func payoutForPosition(market Market, position Position) int64 {
	if market.Outcome == verdict.OutcomeInvalid {
		stake, ok := overflow.Add64(position.YesStake, position.NoStake)
		if !ok {
			panic("position overflow")
		}
		return stake
	}

	shares := position.NoStake
	if market.Outcome == verdict.OutcomeYes {
		shares = position.YesStake
	}
	if shares <= 0 {
		return 0
	}

	pool := winningPoolFor(market, market.Outcome)
	payout := verdict.CalculatePayout(shares, pool, totalPool(market), 0)
	if shares == market.RemainingWinningShares {
		return market.RemainingClaimable
	}
	return payout
}

func recordRealizedNet(account address, delta int64) {
	participant, ok := participantByAddress(account)
	if !ok {
		participant = Participant{Address: account}
	}
	updated, ok := overflow.Add64(participant.RealizedNet, delta)
	if !ok {
		panic("leaderboard overflow")
	}
	participant.RealizedNet = updated
	participants.Set(participantKey(account), participant)
}
