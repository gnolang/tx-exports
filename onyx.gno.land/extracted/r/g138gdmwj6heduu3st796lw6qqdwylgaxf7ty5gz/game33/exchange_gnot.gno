package game33

// ── P2P exchange: COIN/GNOT constant-product pools ───────────────────────────
//
// Mirrors exchange_pool.gno exactly, but the hub side is "gnot" (internal
// pseudo-coin representing deposited ugnot) instead of "grin".
//
// Pool keys use the coin ID directly (e.g. "fire", "cool") — they live in a
// separate AVL tree (gnotPools) so they cannot collide with the COIN/GRIN
// pools in the `pools` tree.
//
// Players must call DepositGnot (exchange_core.gno) first to wrap ugnot into
// internal "gnot" balance before they can trade or provide liquidity here.
// WithdrawGnot unwraps "gnot" back to real ugnot at any time.
//
// Security properties identical to exchange_pool.gno:
//   - All amounts uint64, all arithmetic checked (no wraps).
//   - Rounding always favors the pool.
//   - Reserves are internal counters — no banker calls here.
//   - RemoveGnotLiquidity works while paused or banned (it's an exit).
//   - minLiquidity (1000) shares burned on first deposit (sandwich resistance).

import (
	"strconv"
	"time"

	"chain"

	"gno.land/p/nt/avl/v0"
)

var (
	gnotPools       avl.Tree // coin → *pool  (reuses the pool struct from exchange_pool.gno)
	gnotLpPositions avl.Tree // coin+":"+addr → *lpPos
)

// gnotPool returns the COIN/GNOT pool for coin, panicking if it doesn't exist.
func gnotPool(coin string) *pool {
	if !gnotPools.Has(coin) {
		panic("no GNOT pool for " + coin)
	}
	return gnotPools.Get(coin).(*pool)
}

// ── Write functions ───────────────────────────────────────────────────────────

// OpenGnotPool creates a new COIN/GNOT pool and seeds the first liquidity,
// atomically setting the opening price. Any player who holds the coin and
// enough deposited GNOT can call this — no admin required.
//
// coinAmt/gnotAmt set the price ratio; whoever opens the pool first controls
// the opening price. 1,000 shares are permanently burned as a seed.
func OpenGnotPool(cur realm, coin string, coinAmt uint64, gnotAmt uint64, minShares uint64, deadline int64) uint64 {
	caller := exchangeCaller(cur)
	requireMarketOpen(caller)
	requireDeadline(deadline)
	requireAmount("coinAmt", coinAmt)
	requireAmount("gnotAmt", gnotAmt)
	if coin == hubCoin {
		panic("grin has its own COIN/GRIN pool: use OpenPool")
	}
	if coin == gnotCoinId {
		panic("cannot open a GNOT/GNOT pool")
	}
	requireCoin(coin)
	if gnotPools.Has(coin) {
		panic("GNOT pool already exists: use AddGnotLiquidity to stake")
	}
	s := isqrt128(coinAmt, gnotAmt)
	if s <= minLiquidity {
		panic("first deposit too small: sqrt(coinAmt x gnotAmt) must exceed 1000")
	}
	minted := s - minLiquidity
	if minted < minShares {
		panic("slippage: shares below minimum")
	}
	requireBalance(caller, coin, coinAmt)
	requireBalance(caller, gnotCoinId, gnotAmt)
	// ── all checks passed; writes start here ──
	p := &pool{coin: coin}
	gnotPools.Set(coin, p)
	p.shares = addChk(minted, minLiquidity)
	debitBal(caller, coin, coinAmt)
	debitBal(caller, gnotCoinId, gnotAmt)
	p.rCoin = coinAmt
	p.rHub = gnotAmt
	now := time.Now().Unix()
	rk := rootKPerShare(p)
	gnotLpPositions.Set(coin+":"+caller, &lpPos{shares: minted, entryRKPS: rk, depositTs: now})
	chain.Emit("GnotPoolCreated", "coin", coin)
	chain.Emit("GnotLiquidityAdded", "coin", coin, "who", caller,
		"coinIn", u(coinAmt), "gnotIn", u(gnotAmt), "shares", u(minted))
	return minted
}

// AddGnotLiquidity deposits up to coinMax of `coin` and gnotMax internal GNOT.
// Follows the current pool ratio. Reverts unless at least minShares are minted.
func AddGnotLiquidity(cur realm, coin string, coinMax uint64, gnotMax uint64, minShares uint64, deadline int64) uint64 {
	caller := exchangeCaller(cur)
	requireMarketOpen(caller)
	requireDeadline(deadline)
	requireAmount("coinMax", coinMax)
	requireAmount("gnotMax", gnotMax)
	p := gnotPool(coin)
	if p.paused {
		panic("GNOT pool paused")
	}
	var aCoin, aHub, minted uint64
	if p.shares == 0 {
		aCoin, aHub = coinMax, gnotMax
		s := isqrt128(aCoin, aHub)
		if s <= minLiquidity {
			panic("first deposit too small: sqrt(coin×gnot) must exceed 1000")
		}
		minted = s - minLiquidity
	} else {
		aHub = gnotMax
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
	requireBalance(caller, gnotCoinId, aHub)
	// ── all checks passed; writes start here ──
	if p.shares == 0 {
		p.shares = addChk(minted, minLiquidity)
	} else {
		p.shares = addChk(p.shares, minted)
	}
	debitBal(caller, coin, aCoin)
	debitBal(caller, gnotCoinId, aHub)
	p.rCoin = addChk(p.rCoin, aCoin)
	p.rHub = addChk(p.rHub, aHub)
	key := coin + ":" + caller
	now := time.Now().Unix()
	rk := rootKPerShare(p)
	if gnotLpPositions.Has(key) {
		pos := gnotLpPositions.Get(key).(*lpPos)
		tot := addChk(pos.shares, minted)
		pos.entryRKPS = addChk(mulDiv(pos.entryRKPS, pos.shares, tot), mulDivUp(rk, minted, tot))
		pos.depositTs = int64(addChk(mulDiv(uint64(pos.depositTs), pos.shares, tot), mulDivUp(uint64(now), minted, tot)))
		pos.shares = tot
	} else {
		gnotLpPositions.Set(key, &lpPos{shares: minted, entryRKPS: rk, depositTs: now})
	}
	chain.Emit("GnotLiquidityAdded", "coin", coin, "who", caller,
		"coinIn", u(aCoin), "gnotIn", u(aHub), "shares", u(minted))
	return minted
}

// RemoveGnotLiquidity is always available — works while the exchange or pool
// is paused. Returns (coinOut, gnotOut).
func RemoveGnotLiquidity(cur realm, coin string, shares uint64, minCoin uint64, minGnot uint64, deadline int64) (uint64, uint64) {
	caller := exchangeCaller(cur)
	requireDeadline(deadline)
	p := gnotPool(coin)
	key := coin + ":" + caller
	if !gnotLpPositions.Has(key) {
		panic("no GNOT liquidity position in " + coin)
	}
	pos := gnotLpPositions.Get(key).(*lpPos)
	if shares == 0 || shares > pos.shares {
		panic("invalid shares")
	}
	outCoin, outHub := lpPayout(p, pos, shares, time.Now().Unix())
	if outCoin < minCoin || outHub < minGnot {
		panic("slippage: output below minimum")
	}
	p.rCoin = subChk(p.rCoin, outCoin)
	p.rHub = subChk(p.rHub, outHub)
	p.shares = subChk(p.shares, shares)
	pos.shares = subChk(pos.shares, shares)
	if pos.shares == 0 {
		gnotLpPositions.Remove(key)
	}
	creditBal(caller, coin, outCoin)
	creditBal(caller, gnotCoinId, outHub)
	chain.Emit("GnotLiquidityRemoved", "coin", coin, "who", caller,
		"coinOut", u(outCoin), "gnotOut", u(outHub), "shares", u(shares))
	return outCoin, outHub
}

// poolSwapGnot executes one hop (coin↔gnot) for internal routing.
// The caller's input must already have been debited.
func poolSwapGnot(p *pool, inIsHub bool, amountIn uint64) uint64 {
	if !poolOpenForSwaps(p) {
		panic("GNOT pool " + p.coin + " is not open for swaps (paused or under 2000 gnot depth)")
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
		accrueProtocolFee(gnotCoinId, proto)
	} else {
		p.rCoin = addChk(p.rCoin, inNet)
		p.rHub = subChk(p.rHub, out)
		accrueProtocolFee(p.coin, proto)
	}
	if p.rCoin == 0 || p.rHub == 0 {
		panic("swap would empty the GNOT pool")
	}
	if isqrt128(p.rCoin, p.rHub) < kBefore {
		panic("invariant: k decreased in GNOT pool")
	}
	return out
}

// ── View functions ────────────────────────────────────────────────────────────

// GnotBalance returns the caller's internal GNOT balance (deposited ugnot).
func GnotBalance(addr string) string {
	return u(balOf(addr, gnotCoinId))
}

// GnotPoolInfo returns the state of the COIN/GNOT pool for `coin`.
func GnotPoolInfo(coin string) string {
	if !gnotPools.Has(coin) {
		return `{"coin":` + jsonStr(coin) + `,"exists":false}`
	}
	p := gnotPool(coin)
	return `{"coin":` + jsonStr(coin) + `,"rCoin":"` + u(p.rCoin) + `","rGnot":"` + u(p.rHub) +
		`","shares":"` + u(p.shares) + `","paused":` + strconv.FormatBool(p.paused) +
		`,"open":` + strconv.FormatBool(poolOpenForSwaps(p)) + `}`
}

// GnotPools lists COIN/GNOT pools (paginated, ≤ 50 per call).
func GnotPools(limit int, offset int) string {
	if limit <= 0 || limit > maxViewLimit {
		limit = maxViewLimit
	}
	if offset < 0 {
		offset = 0
	}
	out := "["
	n := 0
	gnotPools.IterateByOffset(offset, limit, func(_ string, v any) bool {
		if n > 0 {
			out += ","
		}
		p := v.(*pool)
		out += `{"coin":` + jsonStr(p.coin) + `,"rCoin":"` + u(p.rCoin) + `","rGnot":"` + u(p.rHub) +
			`","shares":"` + u(p.shares) + `","paused":` + strconv.FormatBool(p.paused) +
			`,"open":` + strconv.FormatBool(poolOpenForSwaps(p)) + `}`
		n++
		return false
	})
	return out + "]"
}

// QuoteGnotSwap quotes a single GNOT-pool swap; "0" if unavailable.
func QuoteGnotSwap(coinIn string, coinOut string, amountIn uint64) string {
	if amountIn == 0 || amountIn > maxAmount {
		return "0"
	}
	c, inIsHub := coinIn, false
	if coinIn == gnotCoinId {
		c, inIsHub = coinOut, true
	} else if coinOut != gnotCoinId {
		return "0" // neither side is gnot — not a GNOT pool swap
	}
	if !gnotPools.Has(c) {
		return "0"
	}
	p := gnotPool(c)
	if !poolOpenForSwaps(p) {
		return "0"
	}
	out, _ := poolQuote(p, inIsHub, amountIn)
	return u(out)
}

// GnotLpPosition shows one GNOT LP position and current withdrawal value.
func GnotLpPosition(coin string, addr string) string {
	key := coin + ":" + addr
	if !gnotLpPositions.Has(key) || !gnotPools.Has(coin) {
		return `{"coin":` + jsonStr(coin) + `,"shares":"0"}`
	}
	pos := gnotLpPositions.Get(key).(*lpPos)
	p := gnotPool(coin)
	now := time.Now().Unix()
	oc, oh := lpPayout(p, pos, pos.shares, now)
	warm := pos.depositTs + warmupSecs - now
	if warm < 0 {
		warm = 0
	}
	return `{"coin":` + jsonStr(coin) + `,"shares":"` + u(pos.shares) + `","poolShares":"` + u(p.shares) +
		`","coinOut":"` + u(oc) + `","gnotOut":"` + u(oh) + `","warmupLeft":` + strconv.FormatInt(warm, 10) + `}`
}

// GnotLpPositions lists all GNOT LP positions for an address (paginated).
func GnotLpPositions(addr string, limit int, offset int) string {
	if limit <= 0 || limit > maxViewLimit {
		limit = maxViewLimit
	}
	if offset < 0 {
		offset = 0
	}
	out := "["
	n := 0
	gnotPools.IterateByOffset(offset, limit, func(coin string, _ any) bool {
		if gnotLpPositions.Has(coin + ":" + addr) {
			if n > 0 {
				out += ","
			}
			out += GnotLpPosition(coin, addr)
			n++
		}
		return false
	})
	return out + "]"
}
