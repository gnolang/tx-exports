package incentives

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/zdex/amm/v1"
	"gno.land/r/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/zdex/v2"
)

// Fund deposits OriginSend ugnot into the pool gauge. Anyone EOA may
// incentivize. Does not call zdex swap or LP — PoolInfo only.
func Fund(cur realm, poolID string) {
	require(cur.Previous().IsUserCall(), "zdex: ugnot is EOA-only")
	require(!paused, "zdex: paused")
	os := unsafe.OriginSend()
	require(len(os) == 1 && os[0].Denom == nativeDenom, "zdex: only ugnot")
	sent := os.AmountOf(nativeDenom)
	require(sent >= minFundUgnot, "zdex: min 1 GNOT")
	_, _, _, totalLP, _ := zdex.PoolInfo(poolID)
	require(totalLP > minLiquidity, "zdex: empty pool")
	g := ensureGauge(poolID, true)
	require(g.On, "zdex: gauge off")
	delta := amm.MulDiv(sent, scale, totalLP)
	require(delta > 0, "zdex: dust fund")
	g.Acc = add64(g.Acc, delta)
	g.TotalFunded = add64(g.TotalFunded, sent)
	chain.Emit("Fund", "pool", poolID, "amount", itoa(sent), "acc", itoa(g.Acc))
}

func pendingOf(poolID string, owner address) int64 {
	st := tryStake(poolID, owner)
	if st == nil || st.LastLP <= 0 {
		return 0
	}
	acc := int64(0)
	if g := tryGauge(poolID); g != nil {
		acc = g.Acc
	}
	if acc <= st.LastAcc {
		return 0
	}
	live := zdex.PositionOf(poolID, owner)
	eligible := st.LastLP
	if live < eligible {
		eligible = live
	}
	if eligible <= 0 {
		return 0
	}
	return amm.MulDiv(eligible, acc-st.LastAcc, scale)
}

// Sync pays min(LastLP, live PositionOf) against Acc, then snapshots.
// RemoveLiquidity on v2 without Claim forfeits unclaimed gauge (insolvency).
func Sync(cur realm, poolID string) int64 {
	caller := cur.Previous().Address()
	earned := pendingOf(poolID, caller)
	st := getOrCreateStake(poolID, caller)
	acc := int64(0)
	if g := tryGauge(poolID); g != nil {
		acc = g.Acc
	}
	st.LastLP = zdex.PositionOf(poolID, caller)
	st.LastAcc = acc
	if earned > 0 {
		sendUgnot(0, cur, caller, earned)
	}
	chain.Emit("Sync", "pool", poolID, "to", caller.String(), "earned", itoa(earned))
	return earned
}

func Claim(cur realm, poolID string) int64 {
	return Sync(cur, poolID)
}

func SetGauge(cur realm, poolID string, on bool) {
	mustOwner(cur)
	require(poolID != "", "zdex: pool")
	g := ensureGauge(poolID, on)
	g.On = on
	chain.Emit("SetGauge", "pool", poolID, "on", itoa(btoi(on)))
}

func SetPaused(cur realm, v bool) {
	mustOwner(cur)
	paused = v
	chain.Emit("Pause", "paused", itoa(btoi(v)))
}

func sendUgnot(_ int, rlm realm, to address, amount int64) {
	if !rlm.IsCurrent() {
		panic("zdex: spoofed realm")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: nativeDenom, Amount: amount}})
}
