package gsfarmv3

import (
	"chain"
	"strconv"
	"time"

	"gno.land/r/gnoland/wugnot"
	"gno.land/r/gnoswap/access"
	"gno.land/r/gnoswap/gns"
	"gno.land/r/gnoswap/position"
	"gno.land/r/gnoswap/router"
)

const (
	liveGnsKey        = "gno.land/r/gnoswap/gns.GNS"
	liveWugnotKey     = "gno.land/r/gnoland/wugnot.wugnot"
	liveGnsToWugnot   = "gno.land/r/gnoswap/gns.GNS:gno.land/r/gnoland/wugnot.wugnot:3000"
	liveWugnotToGns   = "gno.land/r/gnoland/wugnot.wugnot:gno.land/r/gnoswap/gns.GNS:3000"
	routerPkg         = "gno.land/r/gnoswap/router"
	poolRole          = "pool"
	feeTier           = uint32(3000)
	tickLower         = int32(-887220)
	tickUpper         = int32(887220)
	maxApprove  int64 = 1_000_000_000_000_000
)

func pullWugnot(cur realm, from address, amount int64) {
	wugnot.TransferFrom(cross(cur), from, cur.Address(), amount)
}

func pushWugnot(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	wugnot.Transfer(cross(cur), to, amount)
}

func idleWugnot() int64 { return wugnot.BalanceOf(g.self) }
func pendingGns() int64 { return gns.BalanceOf(g.self) }

func harvestLP(cur realm) int64 {
	before := wugnot.BalanceOf(cur.Address())
	if g.positionID != 0 && !position.IsBurned(g.positionID) {
		position.CollectFee(cross(cur), g.positionID)
	}
	swapAllGns(cur)
	after := wugnot.BalanceOf(cur.Address())
	if after <= before {
		return 0
	}
	return after - before
}

func swapAllGns(cur realm) {
	amt := gns.BalanceOf(cur.Address())
	if amt <= 0 {
		return
	}
	swapExact(cur, liveGnsKey, liveWugnotKey, liveGnsToWugnot, amt)
}

func swapExact(cur realm, tokenIn, tokenOut, route string, amount int64) {
	if amount <= 0 {
		return
	}
	approveSpend(cur, tokenIn, chain.PackageAddress(routerPkg), amount)
	deadline := time.Now().Unix() + 300
	router.ExactInSingleSwapRoute(
		cross(cur),
		tokenIn,
		tokenOut,
		strconv.FormatInt(amount, 10),
		route,
		"0",
		"0",
		deadline,
		"",
	)
}

func approveSpend(cur realm, tokenKey string, spender address, amount int64) {
	if tokenKey == liveWugnotKey {
		wugnot.Approve(cross(cur), spender, amount)
		return
	}
	if tokenKey == liveGnsKey {
		gns.Approve(cross(cur), spender, amount)
		return
	}
	panic("unknown token")
}

func poolAddr() address {
	return access.MustGetAddress(poolRole)
}

func approvePool(cur realm) {
	pa := poolAddr()
	wugnot.Approve(cross(cur), pa, maxApprove)
	gns.Approve(cross(cur), pa, maxApprove)
}
