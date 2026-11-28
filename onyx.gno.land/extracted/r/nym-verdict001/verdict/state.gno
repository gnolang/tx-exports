package verdict

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"math/overflow"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
)

var (
	admin               address
	realmAddr           address
	realmPkgPath        string
	defaultBond         int64
	arbiterQuorum       int
	arbiters            avl.Tree // addr.String() -> bool
	nextMarketID        seqid.ID
	markets             avl.Tree // seqid.ID(id).String() -> *market
	claimableBonds      avl.Tree // addr.String() -> int64
	totalCollateral     int64
	totalFeePool        int64
	totalActiveBonds    int64
	totalClaimableBonds int64
	protocolDustPool    int64
	totalVolume         int64
	totalTrades         int64
	resolvedMarketCount int
	router              *mux.Router
)

func init() {
	admin = unsafe.OriginCaller()
	realmAddr = unsafe.CurrentRealm().Address()
	realmPkgPath = unsafe.CurrentRealm().PkgPath()
	defaultBond = DefaultBondAmount
	arbiterQuorum = 1
	arbiters.Set(admin.String(), true)
	router = buildRouter()
}

func requireAdmin(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("invalid realm")
	}
	if rlm.Previous().Address() != admin {
		panic("admin only")
	}
}

// requireEOAPayment enforces direct MsgCall origin and single-denom ugnot receipt.
func requireEOAPayment(_ int, rlm realm, minAmount int64) int64 {
	if !rlm.IsCurrent() {
		panic("invalid realm")
	}
	if !rlm.Previous().IsUserCall() {
		panic("direct EOA MsgCall required")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic("expected single ugnot coin")
	}
	amt := sent[0].Amount
	if amt <= 0 || amt < minAmount {
		panic("insufficient ugnot sent")
	}
	return amt
}

func requireExactEOAPayment(_ int, rlm realm, exactAmount int64) int64 {
	if !rlm.IsCurrent() {
		panic("invalid realm")
	}
	amt := requireEOAPayment(0, rlm, exactAmount)
	if amt != exactAmount {
		panic("exact ugnot amount required")
	}
	return amt
}

func sendUgnot(_ int, rlm realm, to address, amount int64) {
	if !rlm.IsCurrent() {
		panic("invalid realm")
	}
	if amount <= 0 {
		return
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bnk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: Denom, Amount: amount}})
}

func creditClaimableBond(addr address, amount int64) {
	if amount <= 0 {
		return
	}
	key := addr.String()
	var prev int64
	if raw := claimableBonds.Get(key); raw != nil {
		v, ok := raw.(int64)
		if !ok {
			panic("corrupt claimable bond entry")
		}
		prev = v
	}
	next, ok := overflow.Add64(prev, amount)
	if !ok {
		panic("claimable bond overflow")
	}
	claimableBonds.Set(key, next)

	nextTotal, ok := overflow.Add64(totalClaimableBonds, amount)
	if !ok {
		panic("total claimable bonds overflow")
	}
	totalClaimableBonds = nextTotal
}

func getMarketOrPanic(id uint64) *market {
	if id == 0 {
		panic("market not found")
	}
	raw := markets.Get(seqid.ID(id).String())
	if raw == nil {
		panic("market not found")
	}
	m, ok := raw.(*market)
	if !ok {
		panic("corrupt market entry")
	}
	return m
}

func getPositionTree(m *market) *avl.Tree {
	if m.positions == nil {
		panic("corrupt positions tree")
	}
	return m.positions
}

func getPositionOrNil(m *market, addr address) *position {
	tree := getPositionTree(m)
	raw := tree.Get(addr.String())
	if raw == nil {
		return nil
	}
	pos, ok := raw.(*position)
	if !ok {
		panic("corrupt position entry")
	}
	return pos
}

func getOrCreatePosition(m *market, addr address) *position {
	tree := getPositionTree(m)
	key := addr.String()
	if raw := tree.Get(key); raw != nil {
		pos, ok := raw.(*position)
		if !ok {
			panic("corrupt position entry")
		}
		return pos
	}
	pos := &position{}
	tree.Set(key, pos)
	return pos
}

func pruneEmptyPosition(m *market, addr address, pos *position) {
	if pos.yesShares == 0 && pos.noShares == 0 && pos.lpShares == 0 && pos.pendingFees == 0 && !pos.claimed {
		tree := getPositionTree(m)
		tree.Remove(addr.String())
	}
}

func recordPricePoint(m *market, ts, yesProbBps, volume int64) {
	n := len(m.priceHistory)
	if n > 0 && m.priceHistory[n-1].timestamp == ts {
		m.priceHistory[n-1].yesProbBps = yesProbBps
		m.priceHistory[n-1].volume = volume
		return
	}
	m.priceHistory = append(m.priceHistory, pricePoint{
		timestamp:  ts,
		yesProbBps: yesProbBps,
		volume:     volume,
	})
	if len(m.priceHistory) <= MaxPriceHistory {
		return
	}
	// Downsample evenly while preserving pts[0] (open) and the latest tick.
	compacted := make([]pricePoint, MaxPriceHistory)
	compacted[0] = m.priceHistory[0]
	lastIdx := len(m.priceHistory) - 1
	slots := MaxPriceHistory - 2
	for i := 1; i <= slots; i++ {
		srcIdx := (i * (lastIdx - 1)) / slots
		if srcIdx < 1 {
			srcIdx = 1
		}
		compacted[i] = m.priceHistory[srcIdx]
	}
	compacted[MaxPriceHistory-1] = m.priceHistory[lastIdx]
	m.priceHistory = compacted
}
