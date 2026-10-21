package game33

// ── P2P exchange: router (book first while it beats the pool, rest via pools)

import (
	"strconv"
	"time"

	"chain"
)

// poolPathOut quotes amountIn of coinIn → coinOut through the grin pools
// (one hop if either side is grin, else coinIn→grin→coinOut). ok=false if a
// needed pool is missing or not open. Read-only.
func poolPathOut(coinIn, coinOut string, amountIn uint64) (uint64, bool) {
	if amountIn == 0 || coinIn == coinOut {
		return 0, false
	}
	if coinIn == hubCoin || coinOut == hubCoin {
		c, inIsHub := coinIn, false
		if coinIn == hubCoin {
			c, inIsHub = coinOut, true
		}
		if !pools.Has(c) {
			return 0, false
		}
		p := getPool(c)
		if !poolOpenForSwaps(p) {
			return 0, false
		}
		out, _ := poolQuote(p, inIsHub, amountIn)
		return out, out > 0
	}
	mid, ok := poolPathOut(coinIn, hubCoin, amountIn)
	if !ok {
		return 0, false
	}
	return poolPathOut(hubCoin, coinOut, mid)
}

// gnotPathOut quotes amountIn of coinIn → coinOut through GNOT pools.
// Handles: gnot↔coin (one GNOT pool hop), coin↔coin via gnot hub (two hops).
// Read-only; ok=false if no suitable GNOT pool exists or is open.
func gnotPathOut(coinIn, coinOut string, amountIn uint64) (uint64, bool) {
	if amountIn == 0 || coinIn == coinOut {
		return 0, false
	}
	if coinIn == gnotCoinId || coinOut == gnotCoinId {
		c, inIsHub := coinIn, false
		if coinIn == gnotCoinId {
			c, inIsHub = coinOut, true
		}
		if !gnotPools.Has(c) {
			return 0, false
		}
		p := gnotPool(c)
		if !poolOpenForSwaps(p) {
			return 0, false
		}
		out, _ := poolQuote(p, inIsHub, amountIn)
		return out, out > 0
	}
	// coin→coin via gnot: coinIn→gnot→coinOut
	mid, ok := gnotPathOut(coinIn, gnotCoinId, amountIn)
	if !ok {
		return 0, false
	}
	return gnotPathOut(gnotCoinId, coinOut, mid)
}

// bestPathOut returns the best available output from either GRIN or GNOT pools.
// Read-only; used by routePlanAny for GNOT-aware routing.
func bestPathOut(coinIn, coinOut string, amountIn uint64) (uint64, bool) {
	gOut, gOk := poolPathOut(coinIn, coinOut, amountIn)
	nOut, nOk := gnotPathOut(coinIn, coinOut, amountIn)
	if gOk && nOk {
		if nOut > gOut {
			return nOut, true
		}
		return gOut, true
	}
	if gOk {
		return gOut, true
	}
	if nOk {
		return nOut, true
	}
	return 0, false
}

// routePlan splits amountIn between book fills (direct pair) and the pool
// path. A book fill is taken while its rate is at least the pool path's
// average rate for the whole remainder; everything else goes to the pools.
func routePlan(caller, coinIn, coinOut string, amountIn uint64, maxFills int, now int64) ([]fillStep, []*order, uint64, uint64, uint64) {
	steps, expired, _, _ := planFills(caller, coinIn, coinOut, amountIn, maxFills, now)
	var take []fillStep
	remaining := amountIn
	bookOut := uint64(0)
	for _, st := range steps {
		cost := addChk(st.x, mulDivUp(st.x, takerFeeBps, 10000))
		if cost > remaining {
			break
		}
		if pOut, ok := poolPathOut(coinIn, coinOut, remaining); ok {
			// book rate g/cost vs pool average rate pOut/remaining (128-bit compare)
			if mulLess(st.g, remaining, pOut, cost) {
				break
			}
		}
		take = append(take, st)
		remaining = subChk(remaining, cost)
		bookOut = addChk(bookOut, st.g)
	}
	poolOut := uint64(0)
	if remaining > 0 {
		if out, ok := poolPathOut(coinIn, coinOut, remaining); ok {
			poolOut = out
		} else {
			remaining = 0 // no pool path: only the book part executes
		}
	}
	return take, expired, remaining, bookOut, poolOut
}

// SwapRoute swaps up to amountIn of coinIn for at least minOut of coinOut,
// using the order book (direct pair) while it beats the pools and the grin
// pools for the rest. Coins not needed are never debited.
func SwapRoute(cur realm, coinIn string, coinOut string, amountIn uint64, minOut uint64, maxFills int, deadline int64) uint64 {
	caller := exchangeCaller(cur)
	requireMarketOpen(caller)
	requireDeadline(deadline)
	requireAmount("amountIn", amountIn)
	requireCoin(coinIn)
	requireCoin(coinOut)
	if coinIn == coinOut {
		panic("coinIn and coinOut must differ")
	}
	take, expired, poolIn, bookOut, poolOut := routePlan(caller, coinIn, coinOut, amountIn, maxFills, time.Now().Unix())
	planned := addChk(bookOut, poolOut)
	if planned == 0 || planned < minOut {
		panic("slippage: output below minimum")
	}
	need := poolIn
	for _, st := range take {
		need = addChk(need, addChk(st.x, mulDivUp(st.x, takerFeeBps, 10000)))
	}
	requireBalance(caller, coinIn, need)
	// ── all checks passed; writes start here ──
	for _, o := range expired {
		closeOrder(o, "expired")
	}
	out := executeFills(caller, coinIn, take)
	if poolIn > 0 {
		debitBal(caller, coinIn, poolIn)
		if coinIn == hubCoin {
			out = addChk(out, poolSwap(getPool(coinOut), true, poolIn))
		} else if coinOut == hubCoin {
			out = addChk(out, poolSwap(getPool(coinIn), false, poolIn))
		} else {
			mid := poolSwap(getPool(coinIn), false, poolIn)
			out = addChk(out, poolSwap(getPool(coinOut), true, mid))
		}
	}
	if out != planned {
		panic("invariant: route plan mismatch")
	}
	creditBal(caller, coinOut, out)
	chain.Emit("SwapRouted", "who", caller, "in", coinIn, "out", coinOut, "amountIn", u(amountIn),
		"bookFills", strconv.Itoa(len(take)), "poolIn", u(poolIn), "amountOut", u(out))
	return out
}

// QuoteRoute previews SwapRoute: how much goes to the book vs the pools and
// the expected output (fees included).
func QuoteRoute(caller string, coinIn string, coinOut string, amountIn uint64, maxFills int) string {
	if amountIn == 0 || amountIn > maxAmount || coinIn == coinOut {
		return `{"out":"0"}`
	}
	if _, ok := coinRarity[coinIn]; !ok {
		return `{"out":"0"}`
	}
	if _, ok := coinRarity[coinOut]; !ok {
		return `{"out":"0"}`
	}
	take, _, poolIn, bookOut, poolOut := routePlan(caller, coinIn, coinOut, amountIn, maxFills, time.Now().Unix())
	bookIn := uint64(0)
	for _, st := range take {
		bookIn = addChk(bookIn, addChk(st.x, mulDivUp(st.x, takerFeeBps, 10000)))
	}
	return `{"bookIn":"` + u(bookIn) + `","bookOut":"` + u(bookOut) + `","bookFills":` + strconv.Itoa(len(take)) +
		`,"poolIn":"` + u(poolIn) + `","poolOut":"` + u(poolOut) + `","out":"` + u(addChk(bookOut, poolOut)) +
		`","unused":"` + u(amountIn-bookIn-poolIn) + `"}`
}

// ── GNOT-aware routing ────────────────────────────────────────────────────────
//
// SwapRouteGnot and QuoteRouteGnot mirror SwapRoute/QuoteRoute but accept
// gnotCoinId ("gnot") as either coinIn or coinOut (or both sides being game
// coins routed through GNOT pools). They bypass requireCoin for "gnot" since
// that pseudo-coin is not in coinRarity.

// requireCoinOrGnot validates a coin for GNOT-aware routes.
func requireCoinOrGnot(coin string) {
	if coin == gnotCoinId {
		return
	}
	requireCoin(coin)
}

// gnotRoutePlan is routePlan extended to also check GNOT pools. It uses
// bestPathOut (max of GRIN and GNOT pool outputs) for the pool comparison.
func gnotRoutePlan(caller, coinIn, coinOut string, amountIn uint64, maxFills int, now int64) ([]fillStep, []*order, uint64, uint64, uint64) {
	steps, expired, _, _ := planFills(caller, coinIn, coinOut, amountIn, maxFills, now)
	var take []fillStep
	remaining := amountIn
	bookOut := uint64(0)
	for _, st := range steps {
		cost := addChk(st.x, mulDivUp(st.x, takerFeeBps, 10000))
		if cost > remaining {
			break
		}
		if pOut, ok := bestPathOut(coinIn, coinOut, remaining); ok {
			if mulLess(st.g, remaining, pOut, cost) {
				break
			}
		}
		take = append(take, st)
		remaining = subChk(remaining, cost)
		bookOut = addChk(bookOut, st.g)
	}
	poolOut := uint64(0)
	if remaining > 0 {
		if out, ok := bestPathOut(coinIn, coinOut, remaining); ok {
			poolOut = out
		} else {
			remaining = 0
		}
	}
	return take, expired, remaining, bookOut, poolOut
}

// executeGnotPoolSwap executes the pool leg of a GNOT-aware swap, choosing
// the better route (GRIN or GNOT pools) for the given pair.
func executeGnotPoolSwap(coinIn, coinOut string, poolIn uint64) uint64 {
	if poolIn == 0 {
		return 0
	}
	// Try GNOT pool path first if it gives better output than GRIN path.
	gnotOut, gnotOk := gnotPathOut(coinIn, coinOut, poolIn)
	grinOut, grinOk := poolPathOut(coinIn, coinOut, poolIn)

	useGnot := gnotOk && (!grinOk || gnotOut >= grinOut)

	if useGnot {
		// Execute via GNOT pools
		if coinIn == gnotCoinId {
			return poolSwapGnot(gnotPool(coinOut), true, poolIn)
		} else if coinOut == gnotCoinId {
			return poolSwapGnot(gnotPool(coinIn), false, poolIn)
		} else {
			// coin→coin via gnot: coinIn→gnot→coinOut
			mid := poolSwapGnot(gnotPool(coinIn), false, poolIn)
			return poolSwapGnot(gnotPool(coinOut), true, mid)
		}
	} else if grinOk {
		// Execute via GRIN pools (existing logic)
		if coinIn == hubCoin {
			return poolSwap(getPool(coinOut), true, poolIn)
		} else if coinOut == hubCoin {
			return poolSwap(getPool(coinIn), false, poolIn)
		} else {
			mid := poolSwap(getPool(coinIn), false, poolIn)
			return poolSwap(getPool(coinOut), true, mid)
		}
	}
	panic("no pool path available for " + coinIn + "→" + coinOut)
}

// SwapRouteGnot swaps coinIn for coinOut where either side may be "gnot".
// Uses the order book first (same as SwapRoute) then the best available pool
// (GRIN or GNOT, whichever gives better output).
func SwapRouteGnot(cur realm, coinIn string, coinOut string, amountIn uint64, minOut uint64, maxFills int, deadline int64) uint64 {
	caller := exchangeCaller(cur)
	requireMarketOpen(caller)
	requireDeadline(deadline)
	requireAmount("amountIn", amountIn)
	requireCoinOrGnot(coinIn)
	requireCoinOrGnot(coinOut)
	if coinIn == coinOut {
		panic("coinIn and coinOut must differ")
	}
	take, expired, poolIn, bookOut, poolOut := gnotRoutePlan(caller, coinIn, coinOut, amountIn, maxFills, time.Now().Unix())
	planned := addChk(bookOut, poolOut)
	if planned == 0 || planned < minOut {
		panic("slippage: output below minimum")
	}
	need := poolIn
	for _, st := range take {
		need = addChk(need, addChk(st.x, mulDivUp(st.x, takerFeeBps, 10000)))
	}
	requireBalance(caller, coinIn, need)
	// ── all checks passed; writes start here ──
	for _, o := range expired {
		closeOrder(o, "expired")
	}
	out := executeFills(caller, coinIn, take)
	if poolIn > 0 {
		debitBal(caller, coinIn, poolIn)
		out = addChk(out, executeGnotPoolSwap(coinIn, coinOut, poolIn))
	}
	if out != planned {
		panic("invariant: GNOT route plan mismatch")
	}
	creditBal(caller, coinOut, out)
	chain.Emit("SwapRoutedGnot", "who", caller, "in", coinIn, "out", coinOut, "amountIn", u(amountIn),
		"bookFills", strconv.Itoa(len(take)), "poolIn", u(poolIn), "amountOut", u(out))
	return out
}

// QuoteRouteGnot previews SwapRouteGnot (either side may be "gnot").
func QuoteRouteGnot(caller string, coinIn string, coinOut string, amountIn uint64, maxFills int) string {
	if amountIn == 0 || amountIn > maxAmount || coinIn == coinOut {
		return `{"out":"0"}`
	}
	if coinIn != gnotCoinId {
		if _, ok := coinRarity[coinIn]; !ok {
			return `{"out":"0"}`
		}
	}
	if coinOut != gnotCoinId {
		if _, ok := coinRarity[coinOut]; !ok {
			return `{"out":"0"}`
		}
	}
	take, _, poolIn, bookOut, poolOut := gnotRoutePlan(caller, coinIn, coinOut, amountIn, maxFills, time.Now().Unix())
	bookIn := uint64(0)
	for _, st := range take {
		bookIn = addChk(bookIn, addChk(st.x, mulDivUp(st.x, takerFeeBps, 10000)))
	}
	// Determine which pool type serves the route (for informational output)
	gnotOut, gnotOk := gnotPathOut(coinIn, coinOut, poolIn)
	_, grinOk := poolPathOut(coinIn, coinOut, poolIn)
	poolType := "grin"
	if gnotOk && (!grinOk || gnotOut >= poolOut) {
		poolType = "gnot"
	}
	return `{"bookIn":"` + u(bookIn) + `","bookOut":"` + u(bookOut) + `","bookFills":` + strconv.Itoa(len(take)) +
		`,"poolIn":"` + u(poolIn) + `","poolOut":"` + u(poolOut) + `","poolType":"` + poolType + `"` +
		`,"out":"` + u(addChk(bookOut, poolOut)) + `","unused":"` + u(amountIn-bookIn-poolIn) + `"}`
}
