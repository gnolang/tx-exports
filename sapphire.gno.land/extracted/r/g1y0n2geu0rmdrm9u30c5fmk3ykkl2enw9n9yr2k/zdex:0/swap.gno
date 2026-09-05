package zdex

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

// Quote returns the token/ugnot the trader would receive for amountIn.
// tokenIn is "ugnot" or the pool symbol (or registry key).
func Quote(poolID, tokenIn string, amountIn int64) int64 {
	p := getPool(poolID)
	buy := tokenIn == nativeDenom
	if buy {
		return AmountOut(amountIn, p.ReserveU, p.VirtualU, p.ReserveT, 0, p.FeeBps)
	}
	return AmountOut(amountIn, p.ReserveT, 0, p.ReserveU, 0, p.FeeBps)
}

// SwapExactIn executes a swap against a ugnot/token pool.
// tokenIn is "ugnot" (pay with OriginSend) or the pool symbol/key.
// minOut is slippage protection; maxHeight is a deadline (0 = none).
func SwapExactIn(cur realm, poolID, tokenIn string, amountIn, minOut, maxHeight int64) int64 {
	assertNotPaused()
	require(amountIn > 0, "zdex: amountIn")
	require(minOut >= 0, "zdex: minOut")
	if maxHeight > 0 {
		require(height() <= maxHeight, "zdex: expired")
	}

	p := getPool(poolID)
	buy := tokenIn == nativeDenom
	caller := cur.Previous().Address()

	var out int64
	if buy {
		require(cur.Previous().IsUserCall(), "zdex: ugnot swap is EOA-only")
		sent := unsafe.OriginSend().AmountOf(nativeDenom)
		require(sent == amountIn, "zdex: OriginSend mismatch")
		out = AmountOut(amountIn, p.ReserveU, p.VirtualU, p.ReserveT, 0, p.FeeBps)
		require(out >= minOut, "zdex: slippage")
		if height() < p.SnipeUntil && p.SnipeMaxBps > 0 {
			capOut := MulDiv(p.ReserveT, p.SnipeMaxBps, bpsDen)
			require(out <= capOut, "zdex: snipe cap")
		}
		fs := splitFee(amountIn, p.FeeBps, p.CreatorBps, p.ProtocolBps)
		p.ReserveU = add64(p.ReserveU, fs.net+fs.lp)
		p.AccruedU = add64(p.AccruedU, fs.creator+fs.protocol)
		p.ReserveT = sub64(p.ReserveT, out)
		pushToken(0, cur, p.Symbol, caller, out)
	} else {
		require(tokenIn == p.Symbol || tokenIn == p.Token, "zdex: tokenIn")
		out = AmountOut(amountIn, p.ReserveT, 0, p.ReserveU, 0, p.FeeBps)
		require(out >= minOut, "zdex: slippage")
		pullUserToken(0, cur, p.Symbol, caller, amountIn)
		fs := splitFee(amountIn, p.FeeBps, p.CreatorBps, p.ProtocolBps)
		p.ReserveT = add64(p.ReserveT, fs.net+fs.lp)
		p.AccruedT = add64(p.AccruedT, fs.creator+fs.protocol)
		p.ReserveU = sub64(p.ReserveU, out)
		sendUgnot(0, cur, caller, out)
	}

	chain.Emit("Swap",
		"pool", poolID,
		"trader", caller.String(),
		"tokenIn", tokenIn,
		"amountIn", itoa(amountIn),
		"amountOut", itoa(out),
	)
	return out
}

func sendUgnot(_ int, rlm realm, to address, amount int64) {
	if !rlm.IsCurrent() {
		panic("zdex: spoofed realm")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: nativeDenom, Amount: amount}})
}

func takeUgnot(cur realm, amount int64) {
	require(cur.Previous().IsUserCall(), "zdex: ugnot is EOA-only")
	sent := unsafe.OriginSend().AmountOf(nativeDenom)
	require(sent == amount, "zdex: OriginSend mismatch")
}
