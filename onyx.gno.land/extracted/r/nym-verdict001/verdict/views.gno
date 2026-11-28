package verdict

import (
	"chain/banker"

	"gno.land/p/nym-verdict001/fpmm"
)

func buildMarketView(m *market) MarketView {
	return MarketView{
		ID:                 m.id,
		Question:           m.question,
		Description:        m.description,
		Category:           m.category,
		Creator:            m.creator,
		CreatedAt:          m.createdAt,
		CloseTime:          m.closeTime,
		DisputeWindow:      m.disputeWindow,
		BondAmount:         m.bondAmount,
		Status:             m.status,
		StatusLabel:        m.status.String(),
		ReserveYes:         m.pool.ReserveYes,
		ReserveNo:          m.pool.ReserveNo,
		TotalLP:            m.pool.TotalLP,
		FeeBps:             m.pool.FeeBps,
		YesProbBps:         m.pool.YesProbBps(),
		NoProbBps:          m.pool.NoProbBps(),
		Collateral:         m.collateral,
		FeePool:            m.feePool,
		TotalYesOut:        m.totalYesOut,
		TotalNoOut:         m.totalNoOut,
		TotalVolume:        m.totalVolume,
		TradeCount:         m.tradeCount,
		ProposedOutcome:    m.proposedOutcome,
		Proposer:           m.proposer,
		ProposedAt:         m.proposedAt,
		DisputeDeadline:    m.disputeDeadline,
		ProposerBond:       m.proposerBond,
		Disputer:           m.disputer,
		DisputedAt:         m.disputedAt,
		DisputerBond:       m.disputerBond,
		FinalOutcome:       m.finalOutcome,
		FinalOutcomeLabel:  m.finalOutcome.String(),
		ResolvedAt:         m.resolvedAt,
		ArbiterQuorum:      m.arbiterQuorum,
		YesVotes:           m.yesVotes,
		NoVotes:            m.noVotes,
		InvalidVotes:       m.invalidVotes,
		RemainingLP:        m.remainingLP,
		RemainingWinShares: m.remainingWinShares,
	}
}

// GetMarket returns a value copy of a market by ID for vm/qeval_json queries.
func GetMarket(marketID uint64) (MarketView, bool) {
	if marketID == 0 {
		return MarketView{}, false
	}
	// Check existence before calling getMarketOrPanic so read queries don't panic.
	m := getMarketOrNil(marketID)
	if m == nil {
		return MarketView{}, false
	}
	return buildMarketView(m), true
}

func getMarketOrNil(id uint64) *market {
	if id == 0 {
		return nil
	}
	// Walk via seqid.ID(id) matching the key convention used on insert.
	raw := markets.Get(seqidKey(id))
	if raw == nil {
		return nil
	}
	m, ok := raw.(*market)
	if !ok {
		panic("corrupt market entry")
	}
	return m
}

// ListMarkets returns up to limit MarketViews in reverse chronological order.
func ListMarkets(offset, limit int) []MarketView {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 {
		limit = 20
	}
	if limit > MaxPageLimit {
		limit = MaxPageLimit
	}
	out := make([]MarketView, 0, limit)
	markets.ReverseIterateByOffset(offset, limit, func(_ string, val any) bool {
		m, ok := val.(*market)
		if !ok {
			panic("corrupt market entry")
		}
		out = append(out, buildMarketView(m))
		return false
	})
	return out
}

// GetPosition returns a value copy of addr's position in marketID.
func GetPosition(marketID uint64, addr address) PositionView {
	m := getMarketOrNil(marketID)
	if m == nil {
		return PositionView{MarketID: marketID, Address: addr}
	}
	pos := getPositionOrNil(m, addr)
	if pos == nil {
		return PositionView{MarketID: marketID, Address: addr}
	}
	earned := fpmm.ComputePendingLPFee(m.feeAcc, pos.lpShares, pos.feeDebt)
	pendingFees := pos.pendingFees + earned
	if pendingFees > m.feePool {
		pendingFees = m.feePool
	}
	var estClaimable int64
	if m.status == StatusResolved && !pos.claimed {
		sPay, fPay := computePositionClaim(m, pos)
		estClaimable = sPay + fPay
	}
	return PositionView{
		MarketID:     marketID,
		Address:      addr,
		YesShares:    pos.yesShares,
		NoShares:     pos.noShares,
		LPShares:     pos.lpShares,
		PendingFees:  pendingFees,
		EstClaimable: estClaimable,
		Claimed:      pos.claimed,
	}
}

// GetPriceHistory returns a copied slice of probability ticks for marketID.
func GetPriceHistory(marketID uint64) []PricePointView {
	m := getMarketOrNil(marketID)
	if m == nil {
		return nil
	}
	out := make([]PricePointView, len(m.priceHistory))
	for i, pt := range m.priceHistory {
		out[i] = PricePointView{
			Timestamp:  pt.timestamp,
			YesProbBps: pt.yesProbBps,
			Volume:     pt.volume,
		}
	}
	return out
}

// GetClaimableBonds returns the pull-claimable bond balance in ugnot for addr.
func GetClaimableBonds(addr address) int64 {
	raw := claimableBonds.Get(addr.String())
	if raw == nil {
		return 0
	}
	v, ok := raw.(int64)
	if !ok {
		panic("corrupt claimable bond entry")
	}
	return v
}

// GetArbiters returns a deterministic sorted copy of active arbiter addresses.
func GetArbiters() []address {
	out := make([]address, 0, arbiters.Size())
	arbiters.Iterate("", "", func(key string, _ any) bool {
		out = append(out, address(key))
		return false
	})
	return out
}

// GetStats returns protocol-wide accounting totals and live vault balance.
func GetStats() ProtocolStats {
	vaultBal := banker.NewReadonlyBanker().GetCoin(realmAddr, Denom)
	return ProtocolStats{
		Admin:               admin,
		RealmAddress:        realmAddr,
		MarketCount:         markets.Size(),
		ResolvedMarketCount: resolvedMarketCount,
		TotalCollateral:     totalCollateral,
		TotalFeePool:        totalFeePool,
		TotalActiveBonds:    totalActiveBonds,
		TotalClaimableBonds: totalClaimableBonds,
		ProtocolDustPool:    protocolDustPool,
		VaultBalance:        vaultBal,
		TotalVolume:         totalVolume,
		TotalTrades:         totalTrades,
		DefaultBond:         defaultBond,
		ArbiterCount:        arbiters.Size(),
		ArbiterQuorum:       arbiterQuorum,
	}
}

// PreviewBuy returns a stateless buy quote against marketID's live pool.
func PreviewBuy(marketID uint64, buyYes bool, grossCollateral int64) (fpmm.BuyQuote, error) {
	m := getMarketOrPanic(marketID)
	side := fpmm.SideNo
	if buyYes {
		side = fpmm.SideYes
	}
	return m.pool.QuoteBuy(side, grossCollateral)
}

// PreviewSell returns a stateless sell quote against marketID's live pool.
func PreviewSell(marketID uint64, sellYes bool, sharesIn int64) (fpmm.SellQuote, error) {
	m := getMarketOrPanic(marketID)
	side := fpmm.SideNo
	if sellYes {
		side = fpmm.SideYes
	}
	return m.pool.QuoteSell(side, sharesIn)
}

// PreviewAddLiquidity returns a stateless add-liquidity quote against marketID's live pool.
func PreviewAddLiquidity(marketID uint64, collateralIn int64) (fpmm.AddLiquidityQuote, error) {
	m := getMarketOrPanic(marketID)
	return m.pool.QuoteAddLiquidity(collateralIn)
}

// PreviewRemoveLiquidity returns a stateless remove-liquidity quote against marketID's live pool.
func PreviewRemoveLiquidity(marketID uint64, lpShares int64) (fpmm.RemoveLiquidityQuote, error) {
	m := getMarketOrPanic(marketID)
	return m.pool.QuoteRemoveLiquidity(lpShares)
}
