package zdex

import "chain"

// CreatePool seeds a two-sided ugnot/GRC20 pool. The GRC20 must already
// exist (external or internal). Caller sends `amountU` ugnot with the tx
// and must have approved this realm for `amountT` of the token.
func CreatePool(cur realm, tokenKey, symbol string, amountU, amountT, feeBps int64) string {
	assertNotPaused()
	require(cur.Previous().IsUserCall(), "zdex: EOA only")
	require(amountU > 0 && amountT > 0, "zdex: amounts")
	if feeBps == 0 {
		feeBps = defaultFeeBps
	}
	require(feeBps > 0 && feeBps <= maxFeeBps, "zdex: fee")
	require(symbol != "", "zdex: symbol")
	id := poolIDFor(symbol)
	require(tryPool(id) == nil, "zdex: pool exists")

	takeUgnot(cur, amountU)
	caller := cur.Previous().Address()
	pullUserToken(0, cur, symbol, caller, amountT)

	lp := geoMean(amountU, amountT)
	require(lp > minLiquidity, "zdex: tiny LP")
	lpUser := lp - minLiquidity

	p := &Pool{
		ID:          id,
		Token:       tokenKey,
		Symbol:      symbol,
		ReserveU:    amountU,
		ReserveT:    amountT,
		TotalLP:     lp,
		FeeBps:      feeBps,
		Creator:     caller,
		ProtocolBps: poolProtocolFeeBps,
		Internal:    tryTok(symbol) != nil,
	}
	if p.Token == "" {
		if rec := tryTok(symbol); rec != nil {
			p.Token = rec.token.ID()
		} else {
			p.Token = symbol
		}
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
	require(p.ReserveU > 0 && p.ReserveT > 0 && p.TotalLP > 0, "zdex: empty pool")
	require(amountU > 0, "zdex: amountU")
	takeUgnot(cur, amountU)

	tokenIn := MulDiv(amountU, p.ReserveT, p.ReserveU)
	require(tokenIn > 0, "zdex: tokenIn")
	require(tokenIn <= maxToken, "zdex: token slippage")

	caller := cur.Previous().Address()
	pullUserToken(0, cur, p.Symbol, caller, tokenIn)

	lp := MulDiv(amountU, p.TotalLP, p.ReserveU)
	require(lp > 0, "zdex: zero LP")
	require(lp >= minLP, "zdex: min LP")

	p.ReserveU = add64(p.ReserveU, amountU)
	p.ReserveT = add64(p.ReserveT, tokenIn)
	p.TotalLP = add64(p.TotalLP, lp)
	curLP := int64(0)
	if existing := getPos(poolID, caller); existing != nil {
		curLP = existing.LP
	}
	setPos(poolID, caller, add64(curLP, lp))

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

	outU := MulDiv(lp, p.ReserveU, p.TotalLP)
	outT := MulDiv(lp, p.ReserveT, p.TotalLP)
	require(outU >= minU && outT >= minT, "zdex: slippage")
	require(outU < p.ReserveU && outT < p.ReserveT, "zdex: would drain")

	p.ReserveU = sub64(p.ReserveU, outU)
	p.ReserveT = sub64(p.ReserveT, outT)
	p.TotalLP = sub64(p.TotalLP, lp)
	setPos(poolID, caller, st.LP-lp)

	sendUgnot(0, cur, caller, outU)
	pushToken(0, cur, p.Symbol, caller, outT)

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
