package gsfarmv3

import (
	"strconv"
	"time"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/alloc"
	"gno.land/r/gnoland/wugnot"
	"gno.land/r/gnoswap/gns"
	"gno.land/r/gnoswap/position"
)

func ensureIdle(cur realm, need int64) {
	if wugnot.BalanceOf(cur.Address()) >= need {
		return
	}
	unwindAll(cur)
}

func unwindAll(cur realm) {
	if g.positionID == 0 {
		swapAllGns(cur)
		return
	}
	if position.IsBurned(g.positionID) {
		g.positionID = 0
		swapAllGns(cur)
		return
	}
	// CollectFee first so owed fees are not left in the NFT.
	position.CollectFee(cross(cur), g.positionID)
	liq := position.GetPositionLiquidity(g.positionID)
	if liq != "" && liq != "0" {
		deadline := time.Now().Unix() + 300
		position.DecreaseLiquidity(cross(cur), g.positionID, liq, "0", "0", deadline)
	}
	if !position.IsBurned(g.positionID) {
		position.CollectFee(cross(cur), g.positionID)
	}
	if position.IsBurned(g.positionID) {
		g.positionID = 0
	}
	swapAllGns(cur)
}

// syncBookToCash sets the share book to the WUGNOT actually held after
// unwind/swap so PreviewRedeem never promises more than the vault can pay.
func syncBookToCash() {
	have := idleWugnot()
	booked := g.book.TotalAssets()
	if booked > have {
		g.book.TakeLoss(booked - have)
		return
	}
	if have > booked && g.book.TotalShares() > 0 {
		g.book.AddProfit(have - booked)
	}
}

// rebalance deploys idle WUGNOT above the buffer into the GNS/WUGNOT LP.
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
