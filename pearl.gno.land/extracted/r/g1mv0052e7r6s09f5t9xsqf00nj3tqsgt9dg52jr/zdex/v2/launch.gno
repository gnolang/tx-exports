package zdex

import "chain"

// Launch is a legacy bonding-curve minter. zdex product surface is DEX-only
// (CreatePool + swap + LP). Keep this entry so already-launched pools still
// trade; do not expose it in UI or gnoweb.
func Launch(cur realm, name, symbol string, decimals, totalSupply, creatorKeepBps, virtualUgnot, vestBlocks, lockBlocks, snipeBlocks, snipeMaxBps int64) string {
	assertNotPaused()
	require(cur.Previous().IsUserCall(), "zdex: EOA only")
	require(totalSupply > minLiquidity, "zdex: supply too small")
	require(virtualUgnot > 0, "zdex: virtualUgnot")
	require(creatorKeepBps >= 0 && creatorKeepBps <= maxCreatorKeepBps, "zdex: creator keep")
	require(decimals >= 0 && decimals <= 18, "zdex: decimals")
	require(tryPool(poolIDFor(symbol)) == nil, "zdex: pool exists")

	if creatorKeepBps > 0 && vestBlocks < minVestBlocks {
		vestBlocks = minVestBlocks
	}
	if lockBlocks < minLockBlocks {
		lockBlocks = minLockBlocks
	}
	if snipeBlocks <= 0 {
		snipeBlocks = defaultSnipeBlocks
	}
	if snipeMaxBps <= 0 {
		snipeMaxBps = defaultSnipeMaxBps
	}
	require(snipeMaxBps <= maxSnipeMaxBps, "zdex: snipe max")

	creator := cur.Previous().Address()
	keep := MulDiv(totalSupply, creatorKeepBps, bpsDen)
	poolAmt := totalSupply - keep
	require(poolAmt > minLiquidity, "zdex: pool seed too small")

	key := mintInternal(cur, name, symbol, decimals, totalSupply, cur.Address())

	h := height()
	if keep > 0 {
		vests.Set(vestKey(symbol, creator), &Vesting{
			Symbol: symbol,
			Owner:  creator,
			Total:  keep,
			StartH: h,
			EndH:   h + vestBlocks,
		})
	}

	id := poolIDFor(symbol)
	// Burned (unowned) LP so TotalLP > 0: after unlock, others can add.
	// Nobody holds a Position for this seed, so it cannot be withdrawn.
	lp := geoMean(virtualUgnot, poolAmt)
	require(lp > minLiquidity, "zdex: tiny launch LP")
	p := &Pool{
		ID:           id,
		Token:        key,
		Symbol:       symbol,
		Name:         name,
		ReserveU:     0,
		ReserveT:     poolAmt,
		VirtualU:     virtualUgnot,
		TotalLP:      lp,
		FeeBps:       launchFeeBps,
		Creator:      creator,
		CreatorBps:   launchCreatorFeeBps,
		ProtocolBps:  launchProtocolFeeBps,
		Decimals:     decimals,
		UnlockHeight: h + lockBlocks,
		SnipeUntil:   h + snipeBlocks,
		SnipeMaxBps:  snipeMaxBps,
		Launched:     true,
		Internal:     true,
	}
	pools.Set(id, p)

	chain.Emit("Launch",
		"pool", id,
		"symbol", symbol,
		"token", key,
		"supply", itoa(totalSupply),
		"keep", itoa(keep),
		"virtual", itoa(virtualUgnot),
		"lp", itoa(lp),
		"creator", creator.String(),
	)
	return id
}

// ClaimVest releases linearly vested creator tokens.
func ClaimVest(cur realm, symbol string) int64 {
	assertNotPaused()
	owner := cur.Previous().Address()
	v := vests.Get(vestKey(symbol, owner))
	require(v != nil, "zdex: no vesting")
	vs := v.(*Vesting)
	rel := vestedAmount(vs, height())
	delta := rel - vs.Claimed
	require(delta > 0, "zdex: nothing to claim")
	vs.Claimed = rel
	pushToken(0, cur, symbol, owner, delta)
	chain.Emit("ClaimVest", "symbol", symbol, "to", owner.String(), "amount", itoa(delta))
	return delta
}

func vestedAmount(vs *Vesting, h int64) int64 {
	if h <= vs.StartH {
		return 0
	}
	if vs.EndH <= vs.StartH || h >= vs.EndH {
		return vs.Total
	}
	return MulDiv(vs.Total, h-vs.StartH, vs.EndH-vs.StartH)
}

func VestingOf(symbol string, owner address) (total, claimed, releasable int64) {
	v := vests.Get(vestKey(symbol, owner))
	if v == nil {
		return 0, 0, 0
	}
	vs := v.(*Vesting)
	rel := vestedAmount(vs, height())
	return vs.Total, vs.Claimed, rel - vs.Claimed
}
