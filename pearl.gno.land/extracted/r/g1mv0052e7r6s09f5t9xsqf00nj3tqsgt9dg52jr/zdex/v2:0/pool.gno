package zdex

import (
	"chain"

	"gno.land/r/demo/defi/grc20reg"
)

// CreatePool seeds a two-sided ugnot/GRC20 pool. The GRC20 must already
// exist (external or internal). Caller sends `amountU` ugnot with the tx
// and must have approved this realm for `amountT` of the token.
func CreatePool(cur realm, tokenKey, symbol string, amountU, amountT, feeBps int64) string {
	assertNotPaused()
	require(cur.Previous().IsUserCall(), "zdex: EOA only")
	require(amountU > 0 && amountT > 0, "zdex: amounts")
	require(amountU >= minListUgnot, "zdex: min 1 GNOT")
	if feeBps == 0 {
		feeBps = defaultFeeBps
	}
	require(validSwapFee(feeBps), "zdex: fee tier 5/30/100")
	require(symbol != "", "zdex: symbol")
	id := poolIDFor(symbol)
	require(tryPool(id) == nil, "zdex: pool exists")

	takeUgnot(cur, amountU)
	caller := cur.Previous().Address()
	ref := tokenPullKey(tokenKey, symbol)
	pullUserToken(0, cur, ref, caller, amountT)

	lp := geoMean(amountU, amountT)
	require(lp > minLiquidity, "zdex: tiny LP")
	lpUser := lp - minLiquidity

	internal := tryTok(symbol) != nil
	if !internal {
		t := grc20reg.Get(ref)
		require(t != nil, "zdex: unknown token")
		require(t.GetSymbol() == symbol, "zdex: symbol mismatch")
	}
	p := &Pool{
		ID:          id,
		Token:       ref,
		Symbol:      symbol,
		Name:        symbol,
		ReserveU:    amountU,
		ReserveT:    amountT,
		TotalLP:     lp,
		FeeBps:      feeBps,
		Creator:     caller,
		ProtocolBps: poolProtocolFeeBps,
		Internal:    internal,
	}
	pools.Set(id, p)
	setPos(id, caller, lpUser)

	chain.Emit("CreatePool", "pool", id, "lp", itoa(lpUser), "creator", caller.String())
	return id
}

// AddLiquidity deposits ugnot (OriginSend) + token in pool ratio.
func AddLiquidity(cur realm, poolID string, amountU, maxToken, minLP int64) int64 {
	assertNotPaused()
	p := getPool(poolID)
	require(!p.Launched || height() >= p.UnlockHeight, "zdex: launch LP locked")
	require(p.ReserveT > 0 && p.TotalLP > 0, "zdex: empty pool")
	require(amountU > 0, "zdex: amountU")
	baseU := p.ReserveU
	if baseU == 0 {
		baseU = p.VirtualU
	}
	require(baseU > 0, "zdex: no ugnot base")
	takeUgnot(cur, amountU)

	tokenIn := MulDiv(amountU, p.ReserveT, baseU)
	require(tokenIn > 0, "zdex: tokenIn")
	require(tokenIn <= maxToken, "zdex: token slippage")

	caller := cur.Previous().Address()
	pullUserToken(0, cur, poolTokRef(p), caller, tokenIn)

	lp := MulDiv(amountU, p.TotalLP, baseU)
	require(lp > 0, "zdex: zero LP")
	require(lp >= minLP, "zdex: min LP")

	harvestLP(p, caller)
	p.ReserveU = add64(p.ReserveU, amountU)
	p.ReserveT = add64(p.ReserveT, tokenIn)
	p.TotalLP = add64(p.TotalLP, lp)
	curLP := int64(0)
	if existing := getPos(poolID, caller); existing != nil {
		curLP = existing.LP
	}
	setPos(poolID, caller, add64(curLP, lp))
	if st := getPos(poolID, caller); st != nil {
		st.RewardDebt = MulDiv(st.LP, p.AccPoints, ptsScale)
	}

	chain.Emit("AddLiquidity", "pool", poolID, "lp", itoa(lp), "provider", caller.String())
	return lp
}

// RemoveLiquidity burns LP and returns ugnot + token. Blocked on launched
// pools until UnlockHeight (and even then the minimum-liquidity lock remains).
func RemoveLiquidity(cur realm, poolID string, lp, minU, minT int64) (int64, int64) {
	assertNotPaused()
	p := getPool(poolID)
	require(height() >= p.UnlockHeight, "zdex: LP locked")
	require(lp > 0, "zdex: lp")
	require(p.TotalLP > minLiquidity, "zdex: no LP")

	caller := cur.Previous().Address()
	st := getPos(poolID, caller)
	require(st != nil && st.LP >= lp, "zdex: insufficient LP")
	harvestLP(p, caller)

	outU := MulDiv(lp, p.ReserveU, p.TotalLP)
	outT := MulDiv(lp, p.ReserveT, p.TotalLP)
	require(outU >= minU && outT >= minT, "zdex: slippage")
	require(outU < p.ReserveU && outT < p.ReserveT, "zdex: would drain")

	p.ReserveU = sub64(p.ReserveU, outU)
	p.ReserveT = sub64(p.ReserveT, outT)
	p.TotalLP = sub64(p.TotalLP, lp)
	setPos(poolID, caller, st.LP-lp)
	if left := getPos(poolID, caller); left != nil {
		left.RewardDebt = MulDiv(left.LP, p.AccPoints, ptsScale)
	}

	sendUgnot(0, cur, caller, outU)
	pushToken(0, cur, poolTokRef(p), caller, outT)

	chain.Emit("RemoveLiquidity", "pool", poolID, "lp", itoa(lp), "provider", caller.String())
	return outU, outT
}

func PoolInfo(poolID string) (reserveU, reserveT, virtualU, totalLP, feeBps int64) {
	p := getPool(poolID)
	return p.ReserveU, p.ReserveT, p.VirtualU, p.TotalLP, p.FeeBps
}

func PositionOf(poolID string, owner address) int64 {
	st := getPos(poolID, owner)
	if st == nil {
		return 0
	}
	return st.LP
}

func PoolCount() int {
	return pools.Size()
}
