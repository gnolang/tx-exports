package gsfarmv5

import (
	"chain"
	"strconv"
	"time"

	"gno.land/p/gnoswap/deps/tokens/grc721"
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/alloc"
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/poolkey"
	"gno.land/r/gnoswap/access"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/gnft"
	"gno.land/r/gnoswap/position"
	"gno.land/r/gnoswap/router"
	"gno.land/r/gnoswap/staker"
)

const (
	routerPkg        = "gno.land/r/gnoswap/router"
	poolRole         = "pool"
	tickLower        = int32(-887220)
	tickUpper        = int32(887220)
	maxApprove int64 = 1_000_000_000_000_000
)

func assertPoolTokens(spec poolkey.Spec) {
	common.MustRegistered(spec.Token0, spec.Token1)
}

func pullWugnot(cur realm, from address, amount int64) {
	err := common.TransferFrom(cross(cur), poolkey.WugnotKey, from, cur.Address(), amount)
	if err != nil {
		panic(err.Error())
	}
}

func pushWugnot(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	err := common.Transfer(cross(cur), poolkey.WugnotKey, to, amount)
	if err != nil {
		panic(err.Error())
	}
}

func pendingOtherOf(poolPath string) int64 {
	v := g.byPool.Get(poolPath)
	if v == nil {
		return 0
	}
	return common.BalanceOf(v.(*slot).spec.Other, g.self)
}

func harvestLP(cur realm, f *slot) int64 {
	before := common.BalanceOf(poolkey.WugnotKey, cur.Address())
	if f.positionID != 0 && !position.IsBurned(f.positionID) {
		if f.staked {
			staker.CollectReward(cross(cur), f.positionID)
		}
		position.CollectFee(cross(cur), f.positionID)
	}
	swapAllOther(cur, f)
	after := common.BalanceOf(poolkey.WugnotKey, cur.Address())
	if after <= before {
		return 0
	}
	gain := after - before
	f.cash += gain
	return gain
}

func unwindAll(cur realm, f *slot) {
	if f.positionID == 0 {
		swapAllOther(cur, f)
		return
	}
	if position.IsBurned(f.positionID) {
		f.positionID = 0
		swapAllOther(cur, f)
		return
	}
	before := common.BalanceOf(poolkey.WugnotKey, cur.Address())
	unstakeIfNeeded(cur, f)
	position.CollectFee(cross(cur), f.positionID)
	liq := position.GetPositionLiquidity(f.positionID)
	if liq != "" && liq != "0" {
		deadline := time.Now().Unix() + 300
		position.DecreaseLiquidity(cross(cur), f.positionID, liq, "0", "0", deadline)
	}
	if !position.IsBurned(f.positionID) {
		position.CollectFee(cross(cur), f.positionID)
	}
	if position.IsBurned(f.positionID) {
		f.positionID = 0
	}
	swapAllOther(cur, f)
	after := common.BalanceOf(poolkey.WugnotKey, cur.Address())
	if after > before {
		f.cash += after - before
	}
}

func rebalance(cur realm, f *slot) int64 {
	target := alloc.TargetIdle(f.book.TotalAssets(), g.bufferBPS)
	excess := alloc.ExcessIdle(f.cash, target, alloc.MinDeploy)
	if excess == 0 {
		return 0
	}
	half := excess / 2
	if half <= 0 {
		return 0
	}
	before := common.BalanceOf(poolkey.WugnotKey, cur.Address())
	swapExact(cur, poolkey.WugnotKey, f.spec.Other, poolkey.Route(poolkey.WugnotKey, f.spec.Other, f.spec.Fee), half)

	// Spend only this slot's cash above the buffer.
	budget := f.cash - target
	if budget < 0 {
		budget = 0
	}
	gotOther := common.BalanceOf(f.spec.Other, cur.Address())
	if budget == 0 || gotOther == 0 {
		swapAllOther(cur, f)
		after := common.BalanceOf(poolkey.WugnotKey, cur.Address())
		if after > before {
			f.cash += after - before
		} else if before > after {
			spent := before - after
			if spent > f.cash {
				f.cash = 0
			} else {
				f.cash -= spent
			}
		}
		return 0
	}

	approvePool(cur, f)
	deadline := time.Now().Unix() + 300
	amt0, amt1 := mintAmounts(f, budget, gotOther)
	if f.positionID == 0 || position.IsBurned(f.positionID) {
		id, _, _, _ := position.Mint(
			cross(cur),
			f.spec.Token0,
			f.spec.Token1,
			f.spec.Fee,
			tickLower,
			tickUpper,
			amt0,
			amt1,
			"0",
			"0",
			deadline,
			cur.Address(),
			"",
		)
		f.positionID = id
	} else {
		position.IncreaseLiquidity(
			cross(cur),
			f.positionID,
			amt0,
			amt1,
			"0",
			"0",
			deadline,
		)
	}
	swapAllOther(cur, f)
	maybeStake(cur, f)
	after := common.BalanceOf(poolkey.WugnotKey, cur.Address())
	if before <= after {
		return 0
	}
	spent := before - after
	if spent > f.cash {
		f.cash = 0
	} else {
		f.cash -= spent
	}
	return spent
}

func mintAmounts(f *slot, wug, other int64) (string, string) {
	wugS := strconv.FormatInt(wug, 10)
	othS := strconv.FormatInt(other, 10)
	if poolkey.IsWugnot(f.spec.Token0) {
		return wugS, othS
	}
	return othS, wugS
}

func swapAllOther(cur realm, f *slot) {
	amt := common.BalanceOf(f.spec.Other, cur.Address())
	if amt <= 0 {
		return
	}
	if g.stakeEnabled && f.spec.Other == poolkey.GnsKey && !f.staked {
		need := staker.GetDepositGnsAmount()
		if amt > need {
			amt = amt - need
		} else {
			return
		}
	}
	swapExact(cur, f.spec.Other, poolkey.WugnotKey, poolkey.Route(f.spec.Other, poolkey.WugnotKey, f.spec.Fee), amt)
}

func swapExact(cur realm, tokenIn, tokenOut, route string, amount int64) {
	if amount <= 0 {
		return
	}
	common.SafeGRC20Approve(cross(cur), tokenIn, chain.PackageAddress(routerPkg), amount)
	deadline := time.Now().Unix() + 300
	router.ExactInSingleSwapRoute(
		cross(cur),
		tokenIn,
		tokenOut,
		strconv.FormatInt(amount, 10),
		route,
		g.amountOutMin,
		"0",
		deadline,
		"",
	)
}

func unstakeIfNeeded(cur realm, f *slot) {
	if !f.staked || f.positionID == 0 {
		return
	}
	if staker.IsStaked(f.positionID) {
		staker.UnStakeToken(cross(cur), f.positionID)
	}
	f.staked = false
}

func maybeStake(cur realm, f *slot) {
	if !g.stakeEnabled || f.staked || f.positionID == 0 {
		return
	}
	if position.IsBurned(f.positionID) {
		return
	}
	if staker.GetPoolTier(f.spec.Path) == 0 {
		return
	}
	need := staker.GetDepositGnsAmount()
	have := common.BalanceOf(poolkey.GnsKey, cur.Address())
	if have < need {
		return
	}
	stakerAddr := chain.PackageAddress("gno.land/r/gnoswap/staker")
	_ = gnft.Approve(cross(cur), stakerAddr, grc721.TokenID(strconv.FormatUint(f.positionID, 10)))
	common.SafeGRC20Approve(cross(cur), poolkey.GnsKey, stakerAddr, need)
	staker.StakeToken(cross(cur), f.positionID, "")
	f.staked = true
}

func approvePool(cur realm, f *slot) {
	pa := access.MustGetAddress(poolRole)
	common.SafeGRC20Approve(cross(cur), poolkey.WugnotKey, pa, maxApprove)
	common.SafeGRC20Approve(cross(cur), f.spec.Other, pa, maxApprove)
}
