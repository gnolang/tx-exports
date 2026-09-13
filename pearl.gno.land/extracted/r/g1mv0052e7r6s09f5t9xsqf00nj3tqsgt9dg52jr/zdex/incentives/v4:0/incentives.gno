package incentives

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/zdex/amm/v1"
	"gno.land/r/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/zdex/v2"
)

func takeFund(cur realm, poolID string) (sent int64, g *Gauge) {
	require(cur.Previous().IsUserCall(), "zdex: ugnot is EOA-only")
	require(!paused, "zdex: paused")
	os := unsafe.OriginSend()
	require(len(os) == 1 && os[0].Denom == nativeDenom, "zdex: only ugnot")
	sent = os.AmountOf(nativeDenom)
	require(sent >= minFundUgnot, "zdex: min 1 GNOT")
	_, _, _, totalLP, _ := zdex.PoolInfo(poolID)
	require(totalLP > minLiquidity, "zdex: empty pool")
	g = ensureGauge(poolID, true)
	require(g.On, "zdex: gauge off")
	accrue(g)
	return sent, g
}

// Fund deposits OriginSend ugnot into the pool gauge as a lump (duration 0).
// Anyone EOA may incentivize. Does not call zdex swap or LP — PoolInfo only.
func Fund(cur realm, poolID string) {
	sent, g := takeFund(cur, poolID)
	_, _, _, totalLP, _ := zdex.PoolInfo(poolID)
	delta := amm.MulDiv(sent, scale, totalLP)
	require(delta > 0, "zdex: dust fund")
	g.Acc = add64(g.Acc, delta)
	g.TotalFunded = add64(g.TotalFunded, sent)
	chain.Emit("Fund", "pool", poolID, "amount", itoa(sent), "acc", itoa(g.Acc))
}

// FundProgram streams OriginSend ugnot over durationBlocks. Acc is not
// increased until accrue. durationBlocks >= 28800. A later FundProgram
// stacks leftover Remaining into the new window (does not overwrite).
func FundProgram(cur realm, poolID string, durationBlocks int64) {
	require(durationBlocks >= minProgramBlocks, "zdex: duration")
	sent, g := takeFund(cur, poolID)
	_, _, _, totalLP, _ := zdex.PoolInfo(poolID)
	require(amm.MulDiv(sent, scale, totalLP) > 0, "zdex: dust fund")
	pot := add64(g.Remaining, sent)
	rpb := pot / durationBlocks
	require(rpb > 0, "zdex: dust fund")
	now := height()
	g.EndH = add64(now, durationBlocks)
	g.RewardPerBlock = rpb
	g.Remaining = pot
	g.LastH = now
	g.TotalFunded = add64(g.TotalFunded, sent)
	chain.Emit("FundProgram", "pool", poolID, "amount", itoa(sent), "duration", itoa(durationBlocks), "rpb", itoa(rpb))
}

// accrue applies pending program emission to Acc. lastH becomes now, or endH
// if the window has closed.
func accrue(g *Gauge) {
	if g == nil || g.RewardPerBlock <= 0 {
		return
	}
	now := height()
	if now <= g.LastH {
		return
	}
	until := g.EndH
	if now < until {
		until = now
	}
	dt := until - g.LastH
	if dt > 0 && g.Remaining > 0 {
		pay := mul64(g.RewardPerBlock, dt)
		if pay > g.Remaining {
			pay = g.Remaining
		}
		if pay > 0 {
			_, _, _, totalLP, _ := zdex.PoolInfo(g.ID)
			delta := int64(0)
			if totalLP > 0 {
				delta = amm.MulDiv(pay, scale, totalLP)
			}
			if delta == 0 {
				if now >= g.EndH {
					g.LastH = until
				}
				return
			}
			g.Acc = add64(g.Acc, delta)
			g.Remaining = sub64(g.Remaining, pay)
		}
	}
	g.LastH = until
}

func pendingOf(poolID string, owner address) int64 {
	if g := tryGauge(poolID); g != nil {
		accrue(g)
	}
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
	if g := tryGauge(poolID); g != nil {
		accrue(g)
	}
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
		if g := tryGauge(poolID); g != nil {
			g.TotalClaimed = add64(g.TotalClaimed, earned)
		}
		sendUgnot(0, cur, caller, earned)
	}
	chain.Emit("Sync", "pool", poolID, "to", caller.String(), "earned", itoa(earned))
	return earned
}

func ProposeAdmin(cur realm, next address) {
	mustOwner(cur)
	require(next.IsValid(), "zdex: invalid admin")
	pendingAdmin = next
	chain.Emit("ProposeAdmin", "to", next.String())
}

func AcceptAdmin(cur realm) {
	require(pendingAdmin.IsValid(), "zdex: no pending admin")
	require(cur.Previous().Address() == pendingAdmin, "zdex: not pending admin")
	admin = pendingAdmin
	var z address
	pendingAdmin = z
	chain.Emit("AcceptAdmin", "to", admin.String())
}

func PendingAdmin() address {
	return pendingAdmin
}

// SweepDust sends banker ugnot that is not Remaining and not Owed.
// Owner + paused only. Does not touch Claimable / Acc.
func SweepDust(cur realm, to address) int64 {
	mustOwner(cur)
	require(paused, "zdex: unpaused")
	require(to.IsValid(), "zdex: dest")
	reserved := int64(0)
	gauges.Iterate("", "", func(_ string, v any) bool {
		g := v.(*Gauge)
		accrue(g)
		reserved = add64(reserved, g.Remaining)
		return false
	})
	stakes.Iterate("", "", func(_ string, v any) bool {
		st := v.(*Stake)
		reserved = add64(reserved, pendingOf(st.PoolID, st.Owner))
		return false
	})
	rlm := cur
	require(rlm.IsCurrent(), "zdex: spoofed realm")
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bal := bk.GetCoins(rlm.Address()).AmountOf(nativeDenom)
	require(bal > reserved, "zdex: no dust")
	dust := sub64(bal, reserved)
	sendUgnot(0, cur, to, dust)
	chain.Emit("SweepDust", "to", to.String(), "amount", itoa(dust))
	return dust
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
