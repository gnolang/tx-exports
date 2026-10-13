package game29

// ── P2P exchange: COIN/GRIN constant-product pools ───────────────────────────
//
// Reserves are internal counters, never "the realm's balance": a Transfer or
// bank send to the realm address can't move them (no donation attack).
// Rounding: swap fee up, output down, minted shares down, withdrawals down —
// always in the pool's favor. k (and √k per share) never decreases on a swap.

import (
	"std"
	"strconv"
	"time"
)

type pool struct {
	coin        string
	rCoin, rHub uint64 // reserves (coin side, grin side)
	shares      uint64 // total shares, including the burned minLiquidity
	paused      bool   // per-pool: stops new swaps/deposits only
}

type lpPos struct {
	shares    uint64
	entryRKPS uint64 // √k per share × rootKScale at (share-weighted) entry
	depositTs int64  // share-weighted deposit time (warm-up clock)
}

func getPool(coin string) *pool {
	if !pools.Has(coin) {
		panic("no pool for " + coin)
	}
	return pools.Get(coin).(*pool)
}

func rootKPerShare(p *pool) uint64 {
	if p.shares == 0 {
		return 0
	}
	return mulDiv(isqrt128(p.rCoin, p.rHub), rootKScale, p.shares)
}

// CreatePool opens an empty COIN/GRIN pool (admin, per the launch schedule).
// It holds nothing until players deposit; the admin can't deposit for anyone,
// withdraw from it or close it.
func CreatePool(cur realm, coin string) {
	requireAdmin(cur)
	if coin == hubCoin {
		panic("grin is the hub coin: pools are COIN/GRIN")
	}
	requireCoin(coin)
	if pools.Has(coin) {
		panic("pool exists")
	}
	pools.Set(coin, &pool{coin: coin})
	std.Emit("PoolCreated", "coin", coin)
}

// SetPoolPaused stops new swaps and deposits on one pool. Withdrawals stay open.
func SetPoolPaused(cur realm, coin string, p bool) {
	requireAdmin(cur)
	getPool(coin).paused = p
	std.Emit("PoolPaused", "coin", coin, "paused", strconv.FormatBool(p))
}

// AddLiquidity deposits up to coinMax of `coin` and grinMax grin. The first
// deposit sets the price (open economy: any ratio) and burns minLiquidity
// shares; later deposits take the current ratio (never more than either cap).
// Reverts unless at least minShares are minted.
func AddLiquidity(cur realm, coin string, coinMax uint64, grinMax uint64, minShares uint64, deadline int64) uint64 {
	caller := exchangeCaller(cur)
	requireMarketOpen(caller)
	requireDeadline(deadline)
	requireAmount("coinMax", coinMax)
	requireAmount("grinMax", grinMax)
	p := getPool(coin)
	if p.paused {
		panic("pool paused")
	}
	var aCoin, aHub, minted uint64
	if p.shares == 0 {
		aCoin, aHub = coinMax, grinMax
		s := isqrt128(aCoin, aHub)
		if s <= minLiquidity {
			panic("first deposit too small: sqrt(coin×grin) must exceed 1000")
		}
		minted = s - minLiquidity
	} else {
		aHub = grinMax
		aCoin = mulDivUp(aHub, p.rCoin, p.rHub)
		if aCoin > coinMax {
			aCoin = coinMax
			aHub = mulDivUp(aCoin, p.rHub, p.rCoin)
		}
		s1 := mulDiv(aCoin, p.shares, p.rCoin)
		s2 := mulDiv(aHub, p.shares, p.rHub)
		minted = s1
		if s2 < minted {
			minted = s2
		}
		if minted == 0 {
			panic("deposit too small for one share")
		}
	}
	if minted < minShares {
		panic("slippage: shares below minimum")
	}
	requireBalance(caller, coin, aCoin)
	requireBalance(caller, hubCoin, aHub)
	// ── all checks passed; writes start here ──
	if p.shares == 0 {
		p.shares = addChk(minted, minLiquidity) // minLiquidity shares belong to nobody (burned)
	} else {
		p.shares = addChk(p.shares, minted)
	}
	debitBal(caller, coin, aCoin)
	debitBal(caller, hubCoin, aHub)
	p.rCoin = addChk(p.rCoin, aCoin)
	p.rHub = addChk(p.rHub, aHub)

	key := coin + ":" + caller
	now := time.Now().Unix()
	rk := rootKPerShare(p)
	if lpPositions.Has(key) {
		pos := lpPositions.Get(key).(*lpPos)
		tot := addChk(pos.shares, minted)
		pos.entryRKPS = addChk(mulDiv(pos.entryRKPS, pos.shares, tot), mulDivUp(rk, minted, tot))
		// share-weighted deposit time: a top-up restarts the warm-up in proportion.
		pos.depositTs = int64(addChk(mulDiv(uint64(pos.depositTs), pos.shares, tot), mulDivUp(uint64(now), minted, tot)))
		pos.shares = tot
	} else {
		lpPositions.Set(key, &lpPos{shares: minted, entryRKPS: rk, depositTs: now})
	}
	std.Emit("LiquidityAdded", "coin", coin, "who", caller,
		"coinIn", u(aCoin), "grinIn", u(aHub), "shares", u(minted))
	return minted
}

// lpPayout computes what `shares` of a position withdraw right now:
// pro-rata of CURRENT reserves (floor). Within the warm-up the fee growth
// since entry (√k/share above entry) stays in the pool for the other LPs;
// principal is never cut below its entry-value share.
func lpPayout(p *pool, pos *lpPos, shares uint64, now int64) (uint64, uint64) {
	outCoin := mulDiv(shares, p.rCoin, p.shares)
	outHub := mulDiv(shares, p.rHub, p.shares)
	if now-pos.depositTs < warmupSecs {
		rk := rootKPerShare(p)
		if rk > pos.entryRKPS {
			outCoin = mulDiv(outCoin, pos.entryRKPS, rk)
			outHub = mulDiv(outHub, pos.entryRKPS, rk)
		}
	}
	return outCoin, outHub
}

// RemoveLiquidity is instant and ALWAYS available: it works while the
// exchange or the pool is paused, before or after a ban, and needs no tool.
// Nobody but the position owner can call it for that position.
func RemoveLiquidity(cur realm, coin string, shares uint64, minCoin uint64, minGrin uint64, deadline int64) (uint64, uint64) {
	caller := exchangeCaller(cur)
	requireDeadline(deadline)
	p := getPool(coin)
	key := coin + ":" + caller
	if !lpPositions.Has(key) {
		panic("no liquidity position in " + coin)
	}
	pos := lpPositions.Get(key).(*lpPos)
	if shares == 0 || shares > pos.shares {
		panic("invalid shares")
	}
	outCoin, outHub := lpPayout(p, pos, shares, time.Now().Unix())
	if outCoin < minCoin || outHub < minGrin {
		panic("slippage: output below minimum")
	}
	p.rCoin = subChk(p.rCoin, outCoin)
	p.rHub = subChk(p.rHub, outHub)
	p.shares = subChk(p.shares, shares)
	pos.shares = subChk(pos.shares, shares)
	if pos.shares == 0 {
		lpPositions.Remove(key)
	}
	creditBal(caller, coin, outCoin)
	creditBal(caller, hubCoin, outHub)
	std.Emit("LiquidityRemoved", "coin", coin, "who", caller,
		"coinOut", u(outCoin), "grinOut", u(outHub), "shares", u(shares))
	return outCoin, outHub
}

// poolQuote returns (out, protoFee) for amountIn of the input side; no writes.
func poolQuote(p *pool, inIsHub bool, amountIn uint64) (uint64, uint64) {
	rIn, rOut := p.rCoin, p.rHub
	if inIsHub {
		rIn, rOut = p.rHub, p.rCoin
	}
	fee := mulDivUp(amountIn, poolFeeBps, 10000)
	proto := mulDiv(amountIn, protoFeeBps, 10000)
	if fee >= amountIn {
		return 0, 0
	}
	eff := amountIn - fee
	out := mulDiv(rOut, eff, addChk(rIn, eff)) // floor: pool's favor
	return out, proto
}

func poolOpenForSwaps(p *pool) bool {
	return !p.paused && p.rHub >= minOpenDepthGrin && p.rCoin > 0
}

// poolSwap executes one hop (coin↔grin) for `caller`, crediting nothing to
// the caller: it returns the output so routes can chain hops. The caller's
// input must already have been debited.
func poolSwap(p *pool, inIsHub bool, amountIn uint64) uint64 {
	if !poolOpenForSwaps(p) {
		panic("pool " + p.coin + " is not open for swaps (paused or under 2000 grin depth)")
	}
	out, proto := poolQuote(p, inIsHub, amountIn)
	if out == 0 {
		panic("swap too small")
	}
	kBefore := isqrt128(p.rCoin, p.rHub)
	inNet := subChk(amountIn, proto)
	if inIsHub {
		p.rHub = addChk(p.rHub, inNet)
		p.rCoin = subChk(p.rCoin, out)
		accrueProtocolFee(hubCoin, proto)
	} else {
		p.rCoin = addChk(p.rCoin, inNet)
		p.rHub = subChk(p.rHub, out)
		accrueProtocolFee(p.coin, proto)
	}
	if p.rCoin == 0 || p.rHub == 0 {
		panic("swap would empty the pool")
	}
	// Defense in depth: the invariant must hold after every swap.
	if isqrt128(p.rCoin, p.rHub) < kBefore {
		panic("invariant: k decreased")
	}
	return out
}

// SwapExactIn swaps amountIn of coinIn for at least minOut of coinOut through
// one pool (one side must be grin). For X→Y via grin use SwapRoute.
func SwapExactIn(cur realm, coinIn string, coinOut string, amountIn uint64, minOut uint64, deadline int64) uint64 {
	caller := exchangeCaller(cur)
	requireMarketOpen(caller)
	requireDeadline(deadline)
	requireAmount("amountIn", amountIn)
	requireCoin(coinIn)
	requireCoin(coinOut)
	var p *pool
	inIsHub := coinIn == hubCoin
	if inIsHub && coinOut != hubCoin {
		p = getPool(coinOut)
	} else if !inIsHub && coinOut == hubCoin {
		p = getPool(coinIn)
	} else {
		panic("one side must be grin (use SwapRoute for coin→coin)")
	}
	if !poolOpenForSwaps(p) {
		panic("pool " + p.coin + " is not open for swaps (paused or under 2000 grin depth)")
	}
	if q, _ := poolQuote(p, inIsHub, amountIn); q == 0 || q < minOut {
		panic("slippage: output below minimum")
	}
	requireBalance(caller, coinIn, amountIn)
	// ── all checks passed; writes start here ──
	debitBal(caller, coinIn, amountIn)
	out := poolSwap(p, inIsHub, amountIn)
	creditBal(caller, coinOut, out)
	std.Emit("Swap", "pool", p.coin, "who", caller, "in", coinIn, "out", coinOut,
		"amountIn", u(amountIn), "amountOut", u(out))
	return out
}

// ── views ────────────────────────────────────────────────────────────────────

func poolJSON(p *pool) string {
	return `{"coin":` + jsonStr(p.coin) + `,"rCoin":"` + u(p.rCoin) + `","rGrin":"` + u(p.rHub) +
		`","shares":"` + u(p.shares) + `","paused":` + strconv.FormatBool(p.paused) +
		`,"open":` + strconv.FormatBool(poolOpenForSwaps(p)) + `}`
}

func PoolInfo(coin string) string {
	if !pools.Has(coin) {
		return `{"coin":` + jsonStr(coin) + `,"exists":false}`
	}
	return poolJSON(getPool(coin))
}

// Pools lists pools in coin order (paginated, ≤ 50 per call).
func Pools(limit int, offset int) string {
	if limit <= 0 || limit > maxViewLimit {
		limit = maxViewLimit
	}
	if offset < 0 {
		offset = 0
	}
	out := "["
	n := 0
	pools.IterateByOffset(offset, limit, func(_ string, v any) bool {
		if n > 0 {
			out += ","
		}
		out += poolJSON(v.(*pool))
		n++
		return false
	})
	return out + "]"
}

// QuoteSwap quotes a single-pool swap; "0" if the pool can't take it.
func QuoteSwap(coinIn string, coinOut string, amountIn uint64) string {
	if amountIn == 0 || amountIn > maxAmount {
		return "0"
	}
	c, inIsHub := coinIn, false
	if coinIn == hubCoin {
		c, inIsHub = coinOut, true
	} else if coinOut != hubCoin {
		return "0"
	}
	if !pools.Has(c) {
		return "0"
	}
	p := getPool(c)
	if !poolOpenForSwaps(p) {
		return "0"
	}
	out, _ := poolQuote(p, inIsHub, amountIn)
	return u(out)
}

// LpPosition shows one position and what it would withdraw right now.
func LpPosition(coin string, addr string) string {
	key := coin + ":" + addr
	if !lpPositions.Has(key) || !pools.Has(coin) {
		return `{"coin":` + jsonStr(coin) + `,"shares":"0"}`
	}
	pos := lpPositions.Get(key).(*lpPos)
	p := getPool(coin)
	now := time.Now().Unix()
	oc, oh := lpPayout(p, pos, pos.shares, now)
	warm := pos.depositTs + warmupSecs - now
	if warm < 0 {
		warm = 0
	}
	return `{"coin":` + jsonStr(coin) + `,"shares":"` + u(pos.shares) + `","poolShares":"` + u(p.shares) +
		`","coinOut":"` + u(oc) + `","grinOut":"` + u(oh) + `","warmupLeft":` + strconv.FormatInt(warm, 10) + `}`
}

// LpPositions lists an address's positions (bounded: at most one per pool,
// paginated by pool order, ≤ 50 pools scanned per call).
func LpPositions(addr string, limit int, offset int) string {
	if limit <= 0 || limit > maxViewLimit {
		limit = maxViewLimit
	}
	if offset < 0 {
		offset = 0
	}
	out := "["
	n := 0
	pools.IterateByOffset(offset, limit, func(coin string, _ any) bool {
		if lpPositions.Has(coin + ":" + addr) {
			if n > 0 {
				out += ","
			}
			out += LpPosition(coin, addr)
			n++
		}
		return false
	})
	return out + "]"
}
