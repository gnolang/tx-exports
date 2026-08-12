package padv10

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/gnoswap/consts"
	u256 "gno.land/p/gnoswap/uint256"
	"gno.land/r/gnoland/wugnot"
	"gno.land/r/gnoswap/gns"
	gnspool "gno.land/r/gnoswap/pool"
	"gno.land/r/gnoswap/position"
	"gno.land/r/gnoswap/router"
)

// Sapphire Gnoswap registry keys / role addresses (sapphire-1).
const (
	wugnotTokenKey       = "gno.land/r/gnoland/wugnot.wugnot"
	gnsTokenKey          = "gno.land/r/gnoswap/gns.GNS"
	gnoswapPoolAddrStr   = "g1dexaf6aqkkyr9yfy9d5up69lsn7ra80af34g5v"
	gnoswapRouterAddrStr = "g1vc883gshu5z7ytk5cdynhc8c2dh67pdp4cszkp"
)

// tryListOnGnoswap seeds a Gnoswap CL pool with remaining meme tokens + raised-sized
// WUGNOT as LP. CreatePool fee (fixed GNS amount) is paid from:
//  1) pre-funded GNS on pad (preferred â€” immune to GNOT/GNS price moves), else
//  2) ExactOut WUGNOTâ†’GNS using SURPLUS inventory only (above raised), so LP depth
//     stays equal to raised even when GNS is expensive.
//
// Returns true on success. Soft failure sets l.GnoswapNote and returns false
// (caller keeps internal CPMM).
//
// Note: wugnot.Deposit is EOA-only â€” protocol must pre-fund pad with WUGNOT
// (and ideally GNS). Raised ugnot stays on pad as wrap-back backlog.
func tryListOnGnoswap(cur realm, l *Launch, raisedUgnot, remainingTokens int64) bool {
	if raisedUgnot <= 0 || remainingTokens <= 0 {
		l.GnoswapNote = "list skip: empty capital"
		return false
	}
	padAddr := cur.Address()
	wBal := wugnot.BalanceOf(padAddr)
	if wBal < raisedUgnot {
		l.GnoswapNote = "list skip: need WUGNOT inventory >= raised for LP; have " +
			strconv.FormatInt(wBal, 10) + " need " + strconv.FormatInt(raisedUgnot, 10)
		return false
	}

	feeNeed := gnspool.GetPoolCreationFee()
	if feeNeed <= 0 {
		feeNeed = 100_000_000 // 100 GNS default (6 decimals)
	}

	// --- GNS for CreatePool fee (price-sensitive only if we must swap) ---
	gnsBal := gns.BalanceOf(padAddr)
	feeWugnot := int64(0)
	if gnsBal < feeNeed {
		// Fee paid from inventory ABOVE raised so LP size stays = raised.
		// maxIn = min(GnoswapMaxFeeWugnot, surplus) â€” NOT raised/2 (that blocked list at ~10 GNOT/GNS).
		surplus := wBal - raisedUgnot
		if surplus < 1 {
			l.GnoswapNote = "list skip: need GNS on pad or WUGNOT surplus above raised for fee swap; " +
				"CreatePool fee is fixed GNS â€” cost in GNOT moves with market (~1k GNOT/100 GNS at ~10:1)"
			return false
		}
		maxFeeW := GnoswapMaxFeeWugnot
		if maxFeeW > surplus {
			maxFeeW = surplus
		}
		if maxFeeW < 1 {
			l.GnoswapNote = "list skip: fee WUGNOT budget empty"
			return false
		}
		spent, ok := swapWugnotForGNS(cur, feeNeed, maxFeeW)
		if !ok {
			l.GnoswapNote = "list skip: WUGNOTâ†’GNS ExactOut failed (price too high for budget " +
				strconv.FormatInt(maxFeeW, 10) + " ugnot, or thin liquidity). " +
				"Pre-fund " + strconv.FormatInt(feeNeed, 10) + " GNS base units or more WUGNOT surplus."
			return false
		}
		feeWugnot = spent
		gnsBal = gns.BalanceOf(padAddr)
		if gnsBal < feeNeed {
			l.GnoswapNote = "list skip: GNS still short after swap"
			return false
		}
		// Protect LP: after fee spend we must still hold >= raised WUGNOT.
		if wugnot.BalanceOf(padAddr) < raisedUgnot {
			l.GnoswapNote = "list skip: fee swap ate into LP inventory (should not happen with surplus cap)"
			return false
		}
	}

	// LP always seeds full raised-sized WUGNOT (fee never reduces LP when surplus/GNS used).
	liqWugnot := raisedUgnot
	if wugnot.BalanceOf(padAddr) < liqWugnot {
		l.GnoswapNote = "list skip: WUGNOT below raised after fee path"
		return false
	}

	// Mint remaining GRC20 to pad for position.Mint TransferFrom.
	addBal(l, padAddr, remainingTokens)

	tokenKey := adenaKeyFromTokenID(l.TokenID, l.Symbol)
	if tokenKey == "" {
		l.GnoswapNote = "list skip: empty token registry key"
		return false
	}

	// Order tokens lexicographically (Gnoswap requirement).
	t0, t1 := wugnotTokenKey, tokenKey
	amt0, amt1 := liqWugnot, remainingTokens
	if strings.Compare(t0, t1) > 0 {
		t0, t1 = t1, t0
		amt0, amt1 = amt1, amt0
	}

	sqrtPrice := computeSqrtPriceX96(amt0, amt1)
	if sqrtPrice == "" || sqrtPrice == "0" {
		l.GnoswapNote = "list skip: bad sqrtPriceX96"
		return false
	}

	// Approve pool for GNS creation fee + both LP legs.
	poolAddr := address(gnoswapPoolAddrStr)
	gns.Approve(cross(cur), poolAddr, feeNeed)
	wugnot.Approve(cross(cur), poolAddr, liqWugnot)
	if err := l.ledger.Approve(padAddr, poolAddr, remainingTokens); err != nil {
		l.GnoswapNote = "list skip: token approve failed: " + err.Error()
		return false
	}

	// CreatePool (factory reorders tokens + inverts price if needed).
	gnspool.CreatePool(cross(cur), wugnotTokenKey, tokenKey, GnoswapFeeTier, sqrtPrice)

	tickLower, tickUpper := alignedFullRangeTicks(GnoswapTickSpacing)
	deadline := time.Now().Unix() + 600

	posID, liqStr, a0, a1 := position.Mint(
		cross(cur),
		t0,
		t1,
		GnoswapFeeTier,
		tickLower,
		tickUpper,
		strconv.FormatInt(amt0, 10),
		strconv.FormatInt(amt1, 10),
		"0",
		"0",
		deadline,
		padAddr, // permanent lock: pad owns position NFT
		"",
	)

	poolPath := t0 + ":" + t1 + ":" + strconv.FormatUint(uint64(GnoswapFeeTier), 10)
	l.GnoswapListed = true
	l.GnoswapPoolPath = poolPath
	l.GnoswapPositionID = posID
	l.FeeWugnotSpent = feeWugnot
	l.LiqWugnotUsed = liqWugnot
	l.GnoswapNote = "listed pool=" + poolPath + " pos=" + strconv.FormatUint(posID, 10) +
		" liq=" + liqStr + " a0=" + a0 + " a1=" + a1 +
		" feeWugnot=" + strconv.FormatInt(feeWugnot, 10)

	chain.Emit("GnoswapListed",
		"id", l.ID,
		"poolPath", poolPath,
		"positionId", strconv.FormatUint(posID, 10),
		"feeWugnot", strconv.FormatInt(feeWugnot, 10),
		"liqWugnot", strconv.FormatInt(liqWugnot, 10),
		"tokens", strconv.FormatInt(remainingTokens, 10),
	)
	return true
}

// swapWugnotForGNS ExactOut-swaps WUGNOTâ†’GNS. maxInWugnot is a hard ceiling
// (slippage / price protection): if market needs more GNOT for amountOutGNS, swap reverts.
func swapWugnotForGNS(cur realm, amountOutGNS, maxInWugnot int64) (spent int64, ok bool) {
	if amountOutGNS <= 0 || maxInWugnot <= 0 {
		return 0, false
	}
	routerAddr := address(gnoswapRouterAddrStr)
	before := wugnot.BalanceOf(cur.Address())
	if before < maxInWugnot {
		maxInWugnot = before
	}
	if maxInWugnot <= 0 {
		return 0, false
	}
	wugnot.Approve(cross(cur), routerAddr, maxInWugnot)

	route := wugnotTokenKey + ":" + gnsTokenKey + ":" + strconv.FormatUint(uint64(GnoswapFeeTier), 10)
	deadline := time.Now().Unix() + 600
	// ExactOut panics on insufficient maxIn â€” recover as soft fail for graduate fallback.
	// Gno has no recover in production the same way; ExactOut reverts the whole tx if over maxIn.
	// Callers must set maxIn high enough. We still try; panic would revert graduate entirely.
	// Prefer pre-funded GNS to avoid this path under volatile prices.
	inStr, outStr := router.ExactOutSwapRoute(
		cross(cur),
		wugnotTokenKey,
		gnsTokenKey,
		strconv.FormatInt(amountOutGNS, 10),
		route,
		"100",
		strconv.FormatInt(maxInWugnot, 10),
		deadline,
		"",
	)
	_ = outStr
	spentIn, err := strconv.ParseInt(inStr, 10, 64)
	if err != nil || spentIn <= 0 {
		after := wugnot.BalanceOf(cur.Address())
		if after >= before {
			return 0, false
		}
		return before - after, true
	}
	return spentIn, true
}

// computeSqrtPriceX96 returns sqrt(amount1/amount0) * 2^96 as decimal string.
func computeSqrtPriceX96(amount0, amount1 int64) string {
	if amount0 <= 0 || amount1 <= 0 {
		return ""
	}
	a0 := u256.MustFromDecimal(strconv.FormatInt(amount0, 10))
	a1 := u256.MustFromDecimal(strconv.FormatInt(amount1, 10))
	num := u256.Zero().Mul(a1, consts.Q192())
	ratio := u256.Zero().Div(num, a0)
	sqrt := u256Sqrt(ratio)
	if sqrt.Lt(consts.MinSqrtRatio()) {
		return consts.MinSqrtRatio().ToString()
	}
	if sqrt.Gte(consts.MaxSqrtRatio()) {
		return u256.Zero().Sub(consts.MaxSqrtRatio(), u256.One()).ToString()
	}
	return sqrt.ToString()
}

func u256Sqrt(x *u256.Uint) *u256.Uint {
	if x == nil || x.IsZero() {
		return u256.Zero()
	}
	if x.Eq(u256.One()) {
		return u256.One()
	}
	lo := u256.Zero()
	hi := u256.Zero().Add(x, u256.One())
	cap128 := u256.Zero().Lsh(u256.One(), 128)
	if hi.Gt(cap128) {
		hi = cap128.Clone()
	}
	for lo.Lt(u256.Zero().Sub(hi, u256.One())) {
		mid := u256.Zero().Div(u256.Zero().Add(lo, hi), u256.NewUint(2))
		if mid.IsZero() {
			lo = u256.One()
			continue
		}
		sq, overflow := u256.Zero().MulOverflow(mid, mid)
		if overflow || sq.Gt(x) {
			hi = mid
		} else {
			lo = mid
		}
	}
	return lo
}

func alignedFullRangeTicks(spacing int32) (int32, int32) {
	if spacing <= 0 {
		spacing = 60
	}
	tl := (GnoswapMinTick / spacing) * spacing
	tu := (GnoswapMaxTick / spacing) * spacing
	if tl >= tu {
		tl = -spacing
		tu = spacing
	}
	return tl, tu
}

// GnoswapListedOf reports whether a launch was auto-listed on Gnoswap.
func GnoswapListedOf(id string) bool {
	return mustLaunch(id).GnoswapListed
}

// GnoswapPoolPathOf returns the Gnoswap pool path after listing (or empty).
func GnoswapPoolPathOf(id string) string {
	return mustLaunch(id).GnoswapPoolPath
}

// GnoswapNoteOf returns the listing status note.
func GnoswapNoteOf(id string) string {
	return mustLaunch(id).GnoswapNote
}
