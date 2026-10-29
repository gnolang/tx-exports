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
	if isQuoteTok(p, tokenIn) {
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

func normTok(s string) string {
	if s == "" || s == "GNOT" || s == nativeDenom {
		return nativeDenom
	}
	return s
}

// QuoteRoute: GNOT 1-hop, or a direct TOKEN-TOKEN pool, else the 2-hop
// hub (GNOT / USDC / USDT / …) with the highest AmountOut.
func QuoteRoute(tokenIn, tokenOut string, amountIn int64) int64 {
	assertNotPaused()
	require(amountIn > 0, "zdex: amountIn")
	in := normTok(tokenIn)
	out := normTok(tokenOut)
	require(in != out, "zdex: same token")
	if in == nativeDenom {
		p := getPool(poolIDFor(out))
		got := Quote(p.ID, nativeDenom, amountIn)
		assertSnipe(p, got, true)
		return got
	}
	if out == nativeDenom {
		p := getPool(poolIDFor(in))
		got := Quote(p.ID, in, amountIn)
		assertSnipe(p, got, false)
		return got
	}
	if dp := tryPool(pairID(in, out)); dp != nil {
		got := Quote(dp.ID, in, amountIn)
		assertSnipe(dp, got, isQuoteTok(dp, in))
		return got
	}
	_, _, got := bestVia(in, out, amountIn)
	require(got > 0, "zdex: pool not found")
	return got
}

// QuoteRouteSnapshot: tokenIn;tokenOut;hops;mid;amountOut;hub
func QuoteRouteSnapshot(tokenIn, tokenOut string, amountIn int64) string {
	in := normTok(tokenIn)
	out := normTok(tokenOut)
	got := QuoteRoute(in, out, amountIn)
	hops := int64(1)
	mid := int64(0)
	hub := ""
	if in != nativeDenom && out != nativeDenom {
		if tryPool(pairID(in, out)) != nil {
			hops = 1
		} else {
			hops = 2
			hub, mid, got = bestVia(in, out, amountIn)
		}
	}
	line := in + ";" + out + ";" + itoa(hops) + ";" + itoa(mid) + ";" + itoa(got)
	if hub != "" {
		line += ";" + hub
	}
	return line
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
	if p.QuoteSym != "" {
		return swapExactInPair(cur, p, tokenIn, amountIn, minOut)
	}
	buy := tokenIn == nativeDenom
	caller := cur.Previous().Address()

	var out int64
	if buy {
		takeUgnot(cur, amountIn)
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
		rejectStrayUgnot()
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

func swapExactInPair(cur realm, p *Pool, tokenIn string, amountIn, minOut int64) int64 {
	rejectStrayUgnot()
	caller := cur.Previous().Address()
	var out int64
	if isQuoteTok(p, tokenIn) {
		out = AmountOut(amountIn, p.ReserveU, 0, p.ReserveT, 0, p.FeeBps)
		require(out >= minOut, "zdex: slippage")
		assertSnipe(p, out, true)
		pullUserToken(0, cur, p.QuoteTok, caller, amountIn)
		fs := splitFee(amountIn, p.FeeBps, p.CreatorBps, p.ProtocolBps)
		p.ReserveU = add64(p.ReserveU, fs.net+fs.lp)
		creditSwapPoints(p, caller, 0, fs, true)
		p.ReserveT = sub64(p.ReserveT, out)
		pushToken(0, cur, poolTokRef(p), caller, out)
		emitSwap(p, caller, tokenIn, amountIn, out, fs.gross-fs.net)
	} else {
		require(isBaseTok(p, tokenIn), "zdex: tokenIn")
		out = AmountOut(amountIn, p.ReserveT, 0, p.ReserveU, 0, p.FeeBps)
		require(out >= minOut, "zdex: slippage")
		assertSnipe(p, out, false)
		pullUserToken(0, cur, poolTokRef(p), caller, amountIn)
		fs := splitFee(amountIn, p.FeeBps, p.CreatorBps, p.ProtocolBps)
		p.ReserveT = add64(p.ReserveT, fs.net+fs.lp)
		creditSwapPoints(p, caller, 0, fs, false)
		p.ReserveU = sub64(p.ReserveU, out)
		pushToken(0, cur, p.QuoteTok, caller, out)
		emitSwap(p, caller, tokenIn, amountIn, out, fs.gross-fs.net)
	}
	return out
}

func swapSellKeepU(p *Pool, caller address, amountIn int64) int64 {
	out := AmountOut(amountIn, p.ReserveT, 0, p.ReserveU, 0, p.FeeBps)
	require(out > 0, "zdex: zero out")
	assertSnipe(p, out, false)
	fs := splitFee(amountIn, p.FeeBps, p.CreatorBps, p.ProtocolBps)
	p.ReserveT = add64(p.ReserveT, fs.net+fs.lp)
	creditSwapPoints(p, caller, out, fs, false)
	p.ReserveU = sub64(p.ReserveU, out)
	emitSwap(p, caller, p.Symbol, amountIn, out, fs.gross-fs.net)
	return out
}

func swapBuyKeepT(p *Pool, caller address, ugnotIn int64) int64 {
	out := AmountOut(ugnotIn, p.ReserveU, p.VirtualU, p.ReserveT, 0, p.FeeBps)
	require(out > 0, "zdex: zero out")
	assertSnipe(p, out, true)
	fs := splitFee(ugnotIn, p.FeeBps, p.CreatorBps, p.ProtocolBps)
	p.ReserveU = add64(p.ReserveU, fs.net+fs.lp)
	creditSwapPoints(p, caller, ugnotIn, fs, true)
	p.ReserveT = sub64(p.ReserveT, out)
	maybeGraduate(p)
	emitSwap(p, caller, nativeDenom, ugnotIn, out, fs.gross-fs.net)
	return out
}

// SwapRouteExactIn: direct TOKEN-TOKEN pool if it exists; else the 2-hop
// hub with the highest AmountOut. Intermediate stays in the realm banker.
func SwapRouteExactIn(cur realm, tokenIn, tokenOut string, amountIn, minOut, maxHeight int64) int64 {
	assertNotPaused()
	require(amountIn > 0, "zdex: amountIn")
	require(minOut >= 0, "zdex: minOut")
	assertDeadline(maxHeight)
	in := normTok(tokenIn)
	out := normTok(tokenOut)
	require(in != nativeDenom && out != nativeDenom, "zdex: use SwapExactIn")
	require(in != out, "zdex: same token")
	rejectStrayUgnot()
	if dp := tryPool(pairID(in, out)); dp != nil {
		return SwapExactIn(cur, dp.ID, in, amountIn, minOut, maxHeight)
	}
	hub, midQ, gotQ := bestVia(in, out, amountIn)
	require(gotQ > 0, "zdex: pool not found")
	require(gotQ >= minOut, "zdex: slippage")
	p1 := connectPool(in, hub)
	p2 := connectPool(hub, out)
	require(p1 != nil && p2 != nil, "zdex: pool not found")
	caller := cur.Previous().Address()
	pullUserToken(0, cur, in, caller, amountIn)
	mid := applyHopKeep(p1, caller, in, amountIn)
	require(mid == midQ, "zdex: route drifted")
	got := applyHopKeep(p2, caller, hub, mid)
	require(got >= minOut, "zdex: slippage")
	pushToken(0, cur, out, caller, got)
	chain.Emit("Route", "in", in, "out", out, "hub", hub, "amountIn", itoa(amountIn), "mid", itoa(mid), "outAmt", itoa(got))
	return got
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
		sent := originUgnot()
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

	rejectStrayUgnot()
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

func originUgnot() int64 {
	os := unsafe.OriginSend()
	if len(os) == 0 {
		return 0
	}
	require(len(os) == 1, "zdex: OriginSend denom")
	require(os[0].Denom == nativeDenom, "zdex: OriginSend denom")
	return os[0].Amount
}

func rejectStrayUgnot() {
	require(originUgnot() == 0, "zdex: unexpected ugnot")
}

func takeUgnot(cur realm, amount int64) {
	require(amount > 0, "zdex: amount")
	prev := cur.Previous()
	if prev.IsUserCall() {
		require(originUgnot() == amount, "zdex: OriginSend mismatch")
		return
	}
	k := prev.Address().String()
	require(farms.Has(k), "zdex: unknown farm")
	v := farmPay.Get(k)
	require(v != nil, "zdex: farm unpaid")
	have, ok := v.(int64)
	require(ok && have >= amount, "zdex: farm unpaid")
	if have == amount {
		farmPay.Remove(k)
	} else {
		farmPay.Set(k, have-amount)
	}
}
