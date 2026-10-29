package game29

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
