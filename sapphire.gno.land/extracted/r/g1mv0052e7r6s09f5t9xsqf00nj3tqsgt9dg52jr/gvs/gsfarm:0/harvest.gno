package gsfarm

import (
	"chain"
	"strconv"
	"time"

	"gno.land/r/gnoland/wugnot"
	"gno.land/r/gnoswap/gns"
	"gno.land/r/gnoswap/position"
	"gno.land/r/gnoswap/router"
)

// Live Sapphire GnoSwap registry keys (pool path uses these, not Token.ID() with seqid).
const (
	liveGnsKey      = "gno.land/r/gnoswap/gns.GNS"
	liveWugnotKey   = "gno.land/r/gnoland/wugnot.wugnot"
	liveGnsToWugnot = "gno.land/r/gnoswap/gns.GNS:gno.land/r/gnoland/wugnot.wugnot:3000"
	routerPkg       = "gno.land/r/gnoswap/router"
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

func idleWugnot() int64 {
	return wugnot.BalanceOf(g.self)
}

func pendingGns() int64 {
	return gns.BalanceOf(g.self)
}

func harvestGnoswap(cur realm) int64 {
	self := cur.Address()
	before := wugnot.BalanceOf(self)

	ids := PositionIDs()
	for _, id := range ids {
		// LP swap fees on positions the vault owns.
		position.CollectFee(cross(cur), id)
	}
	swapAllGns(cur)

	after := wugnot.BalanceOf(self)
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
	gns.Approve(cross(cur), chain.PackageAddress(routerPkg), amt)
	deadline := time.Now().Unix() + 300
	minOut := strconv.FormatInt(g.minOut, 10)
	router.ExactInSingleSwapRoute(
		cross(cur),
		liveGnsKey,
		liveWugnotKey,
		strconv.FormatInt(amt, 10),
		g.route,
		minOut,
		"0",
		deadline,
		"",
	)
}
