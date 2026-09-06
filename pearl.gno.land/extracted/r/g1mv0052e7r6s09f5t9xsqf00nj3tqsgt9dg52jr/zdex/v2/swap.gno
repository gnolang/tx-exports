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

// QuoteIn returns the input needed so the trader receives at least amountOut
// of tokenOut ("ugnot" or the pool symbol).
func QuoteIn(poolID, tokenOut string, amountOut int64) int64 {
	p := getPool(poolID)
	if tokenOut == nativeDenom {
		return AmountIn(amountOut, p.ReserveT, 0, p.ReserveU, 0, p.FeeBps)
	}
	return AmountIn(amountOut, p.ReserveU, p.VirtualU, p.ReserveT, 0, p.FeeBps)
}

func assertDeadline(maxHeight int64) {
	if maxHeight > 0 {
		require(height() <= maxHeight, "zdex: expired")
	}
}

func assertSnipe(p *Pool, out int64, buy bool) {
	if height() >= p.SnipeUntil || p.SnipeMaxBps <= 0 {
		return
	}
	base := p.ReserveU
	if buy {
		base = p.ReserveT
	}
	capOut := MulDiv(base, p.SnipeMaxBps, bpsDen)
	require(out <= capOut, "zdex: snipe cap")
}

func creditFees(p *Pool, fs feeSplit, ugnotSide bool) {
	if ugnotSide {
		p.AccruedCreatorU = add64(p.AccruedCreatorU, fs.creator)
		p.AccruedProtocolU = add64(p.AccruedProtocolU, fs.protocol)
	} else {
		p.AccruedCreatorT = add64(p.AccruedCreatorT, fs.creator)
		p.AccruedProtocolT = add64(p.AccruedProtocolT, fs.protocol)
	}
}

func emitSwap(p *Pool, trader address, tokenIn string, amountIn, amountOut, fee int64) {
	chain.Emit("Swap",
		"pool", p.ID,
		"trader", trader.String(),
		"tokenIn", tokenIn,
		"amountIn", itoa(amountIn),
		"amountOut", itoa(amountOut),
		"reserveU", itoa(p.ReserveU),
		"reserveT", itoa(p.ReserveT),
		"fee", itoa(fee),
	)
}

// SwapExactIn executes a swap against a ugnot/token pool.
// tokenIn is "ugnot" (pay with OriginSend) or the pool symbol/key.
// minOut is slippage protection; maxHeight is a deadline (0 = none).
func SwapExactIn(cur realm, poolID, tokenIn string, amountIn, minOut, maxHeight int64) int64 {
	assertNotPaused()
	require(amountIn > 0, "zdex: amountIn")
	require(minOut >= 0, "zdex: minOut")
	assertDeadline(maxHeight)

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
		assertSnipe(p, out, true)
		fs := splitFee(amountIn, p.FeeBps, p.CreatorBps, p.ProtocolBps)
		p.ReserveU = add64(p.ReserveU, fs.net+fs.lp)
		creditSwapPoints(p, caller, amountIn, fs, true)
		p.ReserveT = sub64(p.ReserveT, out)
		maybeGraduate(p)
		pushToken(0, cur, poolTokRef(p), caller, out)
		emitSwap(p, caller, tokenIn, amountIn, out, fs.gross-fs.net)
	} else {
		require(tokenIn == p.Symbol || tokenIn == p.Token, "zdex: tokenIn")
		out = AmountOut(amountIn, p.ReserveT, 0, p.ReserveU, 0, p.FeeBps)
		require(out >= minOut, "zdex: slippage")
		assertSnipe(p, out, false)
		pullUserToken(0, cur, poolTokRef(p), caller, amountIn)
		fs := splitFee(amountIn, p.FeeBps, p.CreatorBps, p.ProtocolBps)
		p.ReserveT = add64(p.ReserveT, fs.net+fs.lp)
		creditSwapPoints(p, caller, out, fs, false)
		p.ReserveU = sub64(p.ReserveU, out)
		sendUgnot(0, cur, caller, out)
		emitSwap(p, caller, tokenIn, amountIn, out, fs.gross-fs.net)
	}
	return out
}

// SwapExactOut pays as little as needed to receive amountOut of tokenOut.
// tokenOut is "ugnot" or the pool symbol. maxIn caps what the trader pays.
// Buying tokens: send at least the required ugnot; excess is refunded.
func SwapExactOut(cur realm, poolID, tokenOut string, amountOut, maxIn, maxHeight int64) int64 {
	assertNotPaused()
	require(amountOut > 0, "zdex: amountOut")
	require(maxIn > 0, "zdex: maxIn")
	assertDeadline(maxHeight)

	p := getPool(poolID)
	caller := cur.Previous().Address()
	buy := tokenOut != nativeDenom && tokenOut != ""

	if buy {
		require(tokenOut == p.Symbol || tokenOut == p.Token, "zdex: tokenOut")
		require(cur.Previous().IsUserCall(), "zdex: ugnot swap is EOA-only")
		in := AmountIn(amountOut, p.ReserveU, p.VirtualU, p.ReserveT, 0, p.FeeBps)
		require(in <= maxIn, "zdex: slippage")
		sent := unsafe.OriginSend().AmountOf(nativeDenom)
		require(sent >= in, "zdex: OriginSend mismatch")
		assertSnipe(p, amountOut, true)
		fs := splitFee(in, p.FeeBps, p.CreatorBps, p.ProtocolBps)
		p.ReserveU = add64(p.ReserveU, fs.net+fs.lp)
		creditSwapPoints(p, caller, in, fs, true)
		p.ReserveT = sub64(p.ReserveT, amountOut)
		maybeGraduate(p)
		pushToken(0, cur, poolTokRef(p), caller, amountOut)
		if sent > in {
			sendUgnot(0, cur, caller, sent-in)
		}
		emitSwap(p, caller, nativeDenom, in, amountOut, fs.gross-fs.net)
		return in
	}

	in := AmountIn(amountOut, p.ReserveT, 0, p.ReserveU, 0, p.FeeBps)
	require(in <= maxIn, "zdex: slippage")
	assertSnipe(p, amountOut, false)
	pullUserToken(0, cur, poolTokRef(p), caller, in)
	fs := splitFee(in, p.FeeBps, p.CreatorBps, p.ProtocolBps)
	p.ReserveT = add64(p.ReserveT, fs.net+fs.lp)
	creditSwapPoints(p, caller, amountOut, fs, false)
	p.ReserveU = sub64(p.ReserveU, amountOut)
	sendUgnot(0, cur, caller, amountOut)
	emitSwap(p, caller, p.Symbol, in, amountOut, fs.gross-fs.net)
	return in
}

func maybeGraduate(p *Pool) {
	if p.VirtualU <= 0 || p.ReserveU < p.VirtualU {
		return
	}
	p.VirtualU = 0
	chain.Emit("Graduate", "pool", p.ID, "reserveU", itoa(p.ReserveU))
}

func SpotPrice(poolID string) int64 {
	p := getPool(poolID)
	den := add64(p.ReserveU, p.VirtualU)
	if den <= 0 || p.ReserveT <= 0 {
		return 0
	}
	return MulDiv(p.ReserveT, 1_000_000, den)
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
