package gsfarmv2

import (
	"strconv"
	"time"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/alloc"
	"gno.land/r/gnoland/wugnot"
	"gno.land/r/gnoswap/gns"
	"gno.land/r/gnoswap/position"
)

func ensureIdle(cur realm, need int64) {
	idle := wugnot.BalanceOf(cur.Address())
	if idle >= need {
		return
	}
	if g.positionID == 0 || position.IsBurned(g.positionID) {
		panic("insufficient idle WUGNOT")
	}
	unwindAll(cur)
	if wugnot.BalanceOf(cur.Address()) < need {
		panic("unwind did not cover withdraw")
	}
}

func unwindAll(cur realm) {
	if g.positionID == 0 {
		return
	}
	if position.IsBurned(g.positionID) {
		g.positionID = 0
		return
	}
	liq := position.GetPositionLiquidity(g.positionID)
	if liq == "" || liq == "0" {
		g.positionID = 0
		return
	}
	deadline := time.Now().Unix() + 300
	position.DecreaseLiquidity(cross(cur), g.positionID, liq, "0", "0", deadline)
	if position.IsBurned(g.positionID) {
		g.positionID = 0
	}
	swapAllGns(cur)
}

// rebalance deploys idle WUGNOT above the buffer into the GNS/WUGNOT LP.
// Returns WUGNOT spent toward the LP (best-effort).
func rebalance(cur realm) int64 {
	target := alloc.TargetIdle(g.book.TotalAssets(), g.bufferBPS)
	idle := wugnot.BalanceOf(cur.Address())
	excess := alloc.ExcessIdle(idle, target, alloc.MinDeploy)
	if excess == 0 {
		return 0
	}
	half := excess / 2
	if half <= 0 {
		return 0
	}
	before := wugnot.BalanceOf(cur.Address())
	swapExact(cur, liveWugnotKey, liveGnsKey, liveWugnotToGns, half)

	wug := wugnot.BalanceOf(cur.Address()) - target
	if wug < 0 {
		wug = 0
	}
	gotGns := gns.BalanceOf(cur.Address())
	if wug == 0 || gotGns == 0 {
		swapAllGns(cur)
		return 0
	}

	approvePool(cur)
	deadline := time.Now().Unix() + 300
	if g.positionID == 0 || position.IsBurned(g.positionID) {
		id, _, _, _ := position.Mint(
			cross(cur),
			liveWugnotKey,
			liveGnsKey,
			feeTier,
			tickLower,
			tickUpper,
			strconv.FormatInt(wug, 10),
			strconv.FormatInt(gotGns, 10),
			"0",
			"0",
			deadline,
			cur.Address(),
			"",
		)
		g.positionID = id
	} else {
		position.IncreaseLiquidity(
			cross(cur),
			g.positionID,
			strconv.FormatInt(wug, 10),
			strconv.FormatInt(gotGns, 10),
			"0",
			"0",
			deadline,
		)
	}
	swapAllGns(cur)
	spent := before - wugnot.BalanceOf(cur.Address())
	if spent < 0 {
		return 0
	}
	return spent
}
