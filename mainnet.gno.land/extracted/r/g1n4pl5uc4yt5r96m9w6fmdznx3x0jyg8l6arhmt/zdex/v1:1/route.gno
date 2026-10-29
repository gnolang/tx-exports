package zdex

func connectPool(a, b string) *Pool {
	a = normTok(a)
	b = normTok(b)
	if a == "" || b == "" || a == b {
		return nil
	}
	if a == nativeDenom {
		return tryPool(poolIDFor(b))
	}
	if b == nativeDenom {
		return tryPool(poolIDFor(a))
	}
	return tryPool(pairID(a, b))
}

func otherLeg(p *Pool, tok string) string {
	if p == nil {
		return ""
	}
	if p.QuoteSym != "" {
		if isQuoteTok(p, tok) {
			return p.Symbol
		}
		if isBaseTok(p, tok) {
			return p.QuoteSym
		}
		return ""
	}
	if tok == nativeDenom || tok == "GNOT" {
		return p.Symbol
	}
	if tok == p.Symbol || tok == p.Token {
		return nativeDenom
	}
	return ""
}

func hopIsBuy(p *Pool, tokenIn string) bool {
	if p.QuoteSym != "" {
		return isQuoteTok(p, tokenIn)
	}
	return tokenIn == nativeDenom || tokenIn == "GNOT"
}

func hopSnipeOK(p *Pool, out int64, buy bool) bool {
	if height() >= p.SnipeUntil || p.SnipeMaxBps <= 0 {
		return true
	}
	base := p.ReserveU
	if buy {
		base = p.ReserveT
	}
	return out <= MulDiv(base, p.SnipeMaxBps, bpsDen)
}

func quoteHop(p *Pool, tokenIn string, amountIn int64) int64 {
	if p == nil || amountIn <= 0 {
		return 0
	}
	if p.QuoteSym != "" {
		if isQuoteTok(p, tokenIn) {
			return AmountOut(amountIn, p.ReserveU, 0, p.ReserveT, 0, p.FeeBps)
		}
		if !isBaseTok(p, tokenIn) {
			return 0
		}
		return AmountOut(amountIn, p.ReserveT, 0, p.ReserveU, 0, p.FeeBps)
	}
	if tokenIn == nativeDenom || tokenIn == "GNOT" {
		return AmountOut(amountIn, p.ReserveU, p.VirtualU, p.ReserveT, 0, p.FeeBps)
	}
	if tokenIn != p.Symbol && tokenIn != p.Token {
		return 0
	}
	return AmountOut(amountIn, p.ReserveT, 0, p.ReserveU, 0, p.FeeBps)
}

func hasHub(hubs []string, h string) bool {
	for i := 0; i < len(hubs); i++ {
		if hubs[i] == h {
			return true
		}
	}
	return false
}

func collectHubs(in, out string) []string {
	hubs := []string{nativeDenom, "USDC", "USDT", "DAI"}
	pools.Iterate("", "", func(_ string, v any) bool {
		p := v.(*Pool)
		h := otherLeg(p, in)
		if h != "" && h != in && h != out && !hasHub(hubs, h) {
			hubs = append(hubs, h)
		}
		return false
	})
	return hubs
}

func quoteVia(in, hub, out string, amountIn int64) (mid, got int64) {
	p1 := connectPool(in, hub)
	p2 := connectPool(hub, out)
	if p1 == nil || p2 == nil || p1.ID == p2.ID {
		return 0, 0
	}
	mid = quoteHop(p1, in, amountIn)
	if mid <= 0 || !hopSnipeOK(p1, mid, hopIsBuy(p1, in)) {
		return 0, 0
	}
	got = quoteHop(p2, hub, mid)
	if got <= 0 || !hopSnipeOK(p2, got, hopIsBuy(p2, hub)) {
		return 0, 0
	}
	return mid, got
}

// bestVia picks the 2-hop hub with the highest AmountOut (lowest combined fee+impact).
func bestVia(in, out string, amountIn int64) (hub string, mid, got int64) {
	hubs := collectHubs(in, out)
	for i := 0; i < len(hubs); i++ {
		h := hubs[i]
		if h == in || h == out {
			continue
		}
		m, g := quoteVia(in, h, out, amountIn)
		if g > got {
			hub, mid, got = h, m, g
		}
	}
	return hub, mid, got
}

func applyHopKeep(p *Pool, caller address, tokenIn string, amountIn int64) int64 {
	if p.QuoteSym == "" {
		if tokenIn == nativeDenom || tokenIn == "GNOT" {
			return swapBuyKeepT(p, caller, amountIn)
		}
		return swapSellKeepU(p, caller, amountIn)
	}
	out := quoteHop(p, tokenIn, amountIn)
	require(out > 0, "zdex: zero out")
	assertSnipe(p, out, hopIsBuy(p, tokenIn))
	fs := splitFee(amountIn, p.FeeBps, p.CreatorBps, p.ProtocolBps)
	if isQuoteTok(p, tokenIn) {
		p.ReserveU = add64(p.ReserveU, fs.net+fs.lp)
		creditSwapPoints(p, caller, 0, fs, true)
		p.ReserveT = sub64(p.ReserveT, out)
	} else {
		require(isBaseTok(p, tokenIn), "zdex: tokenIn")
		p.ReserveT = add64(p.ReserveT, fs.net+fs.lp)
		creditSwapPoints(p, caller, 0, fs, false)
		p.ReserveU = sub64(p.ReserveU, out)
	}
	emitSwap(p, caller, tokenIn, amountIn, out, fs.gross-fs.net)
	return out
}


