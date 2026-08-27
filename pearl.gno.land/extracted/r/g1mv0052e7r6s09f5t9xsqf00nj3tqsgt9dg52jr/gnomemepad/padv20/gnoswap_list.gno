package padv20

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

// listFund tracks assets pulled from the listing caller for refund / LP ugnot reimburse.
type listFund struct {
	ok              bool
	caller          address
	pulledLpWugnot  int64 // reimbursed as ugnot after successful list
	pulledFeeWugnot int64 // leftover WUGNOT refunded after list; full refund on fail
	pulledGns       int64 // CreatePool fee; consumed on success
}

// tryListOnGnoswap seeds a Gnoswap CL pool with remaining meme tokens + raised-sized
// WUGNOT as LP. CreatePool fee (fixed GNS amount) is paid from:
//  1) pre-funded GNS on pad (preferred - immune to GNOT/GNS price moves), else
//  2) ExactOut WUGNOT->GNS using SURPLUS inventory only (above raised), so LP depth
//     stays equal to raised even when GNS is expensive.
//
// Returns true on success. Soft failure sets l.GnoswapNote and returns false
// (caller keeps internal CPMM). Does not pull from user - see prepareCallerListFunding.
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

	// --- GNS for CreatePool fee ---
	// Require GNS already on pad. Do NOT Approve+router ExactOut mid-list:
	// realm spender frame often panics "insufficient allowance" and reverts the tx.
	// UI: gns.Transfer(pad, feeNeed) then RetryListGnoswap.
	gnsBal := gns.BalanceOf(padAddr)
	feeWugnot := int64(0)
	if gnsBal < feeNeed {
		l.GnoswapNote = "list skip: need " + strconv.FormatInt(feeNeed, 10) +
			" GNS base units on pad (Transfer GNS then RetryList). have " +
			strconv.FormatInt(gnsBal, 10) +
			". No mid-list WUGNOT->GNS swap (avoids allowance panic)."
		return false
	}

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

	poolAddr := address(gnoswapPoolAddrStr)
	gns.Approve(cross(cur), poolAddr, feeNeed)
	wugnot.Approve(cross(cur), poolAddr, liqWugnot)
	if err := l.ledger.Approve(padAddr, poolAddr, remainingTokens); err != nil {
		l.GnoswapNote = "list skip: token approve failed: " + err.Error()
		return false
	}

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
	// Release Create-time GNS escrow (fee left pad via CreatePool).
	consumeListFeeEscrow(l)
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

// prepareCallerListFunding fills pad inventory shortfall from the EOA caller via TransferFrom.
//
// padv14+ WUGNOT raise: Buy already TransferFrom WUGNOT to pad, so wBal >= raised
// at graduate in the normal case - only GNS fee (or small fee WUGNOT budget) may be short.
//
// Legacy ugnot-raise pads: wugnot.Deposit is EOA-only; caller wraps temp LP then reimbursed.
func prepareCallerListFunding(cur realm, l *Launch, raisedUgnot int64) listFund {
	caller := cur.Previous().Address()
	padA := cur.Address()
	out := listFund{ok: true, caller: caller}

	if raisedUgnot <= 0 {
		l.GnoswapNote = "list skip: empty raise"
		out.ok = false
		return out
	}

	feeNeed := gnspool.GetPoolCreationFee()
	if feeNeed <= 0 {
		feeNeed = 100_000_000
	}

	wBal := wugnot.BalanceOf(padA)
	if wBal < raisedUgnot {
		short := raisedUgnot - wBal
		if !pullWugnotFrom(cur, caller, padA, short) {
			l.GnoswapNote = "list skip: need temp WUGNOT wrap " +
				strconv.FormatInt(short, 10) +
				" ugnot units (Deposit+Approve pad). LP reimbursed from pad ugnot after list. " +
				"Fee: " + strconv.FormatInt(feeNeed, 10) + " GNS or WUGNOT ExactOut budget."
			out.ok = false
			return out
		}
		out.pulledLpWugnot = short
		wBal += short
	}

	gnsBal := gns.BalanceOf(padA)
	if gnsBal < feeNeed {
		gShort := feeNeed - gnsBal
		if pullGnsFrom(cur, caller, padA, gShort) {
			out.pulledGns = gShort
		} else {
			// No GNS from caller - pull modest WUGNOT surplus for ExactOut -> GNS.
			// Do NOT pull full GnoswapMaxFeeWugnot (5000 GNOT) - that causes
			// InsufficientCoins for normal wallets. MaxFee still caps ExactOut spend.
			surplus := wBal - raisedUgnot
			if surplus < 1 {
				feeBudget := listFeeWugnotPull()
				if !pullWugnotFrom(cur, caller, padA, feeBudget) {
					l.GnoswapNote = "list skip: need GNS fee " +
						strconv.FormatInt(feeNeed, 10) +
						" (Approve pad) OR WUGNOT fee budget " +
						strconv.FormatInt(feeBudget, 10) +
						" ugnot for ExactOut. Prefer holding 100 GNS."
					// Roll back LP pull.
					if out.pulledLpWugnot > 0 {
						safeWugnotTransfer(cur, caller, out.pulledLpWugnot)
						out.pulledLpWugnot = 0
					}
					out.ok = false
					return out
				}
				out.pulledFeeWugnot = feeBudget
			}
		}
	}
	return out
}

// listFeeWugnotPull is the WUGNOT amount pulled from the listing caller for
// ExactOut -> GNS when they do not hold CreatePool fee in GNS.
// Kept well below GnoswapMaxFeeWugnot so List does not demand 5k+ GNOT wrap.
func listFeeWugnotPull() int64 {
	const defaultPull int64 = 1_500_000_000 // 1500 GNOT - enough for ~100 GNS at <=15 GNOT/GNS
	if GnoswapMaxFeeWugnot > 0 && GnoswapMaxFeeWugnot < defaultPull {
		return GnoswapMaxFeeWugnot
	}
	return defaultPull
}

// pullWugnotFrom is intentionally a no-op pull.
//
// GRC20 TransferFrom from a realm often panics "insufficient allowance" even when
// Allowance(owner, pad) is set (spender frame resolves to EOA, not pad). Soft-fail
// instead so list can fall back to notes / surplus / pre-funded pad inventory.
//
// UI must pre-fund pad via wugnot.Transfer(pad, amount) and gns.Transfer(pad, fee)
// before RetryListGnoswap - never rely on Approve+TransferFrom in the same flow.
func pullWugnotFrom(cur realm, from, to address, amount int64) bool {
	if amount <= 0 {
		return true
	}
	// Already on pad? treat as satisfied without TransferFrom.
	if wugnot.BalanceOf(to) >= amount && from != to {
		// Not a full check for "raised" accounting - prepareCallerListFunding
		// already compared pad balance to raised before calling shortfall pulls.
	}
	_ = cur
	_ = from
	_ = to
	return false
}

func pullGnsFrom(cur realm, from, to address, amount int64) bool {
	if amount <= 0 {
		return true
	}
	_ = cur
	_ = from
	_ = to
	// Never TransferFrom GNS either (same spender-frame issue).
	return false
}

func safeWugnotTransfer(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	have := wugnot.BalanceOf(cur.Address())
	if have < amount {
		amount = have
	}
	if amount > 0 {
		wugnot.Transfer(cross(cur), to, amount)
	}
}

func safeGnsTransfer(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	have := gns.BalanceOf(cur.Address())
	if have < amount {
		amount = have
	}
	if amount > 0 {
		gns.Transfer(cross(cur), to, amount)
	}
}

func refundCallerListFunding(cur realm, fund listFund) {
	if !fund.caller.IsValid() {
		return
	}
	safeWugnotTransfer(cur, fund.caller, fund.pulledLpWugnot+fund.pulledFeeWugnot)
	safeGnsTransfer(cur, fund.caller, fund.pulledGns)
}

// settleCallerListFunding returns unused fee-budget WUGNOT to the caller.
// LP shortfall pull is rare on WUGNOT-raise pads (raised already on pad); if it
// happened, reimburse in WUGNOT from any leftover pad balance after list.
func settleCallerListFunding(cur realm, fund listFund) {
	if !fund.caller.IsValid() {
		return
	}
	if fund.pulledLpWugnot > 0 {
		safeWugnotTransfer(cur, fund.caller, fund.pulledLpWugnot)
	}
	// Leftover fee-budget WUGNOT (ExactOut may not consume full maxIn).
	if fund.pulledFeeWugnot > 0 {
		safeWugnotTransfer(cur, fund.caller, fund.pulledFeeWugnot)
	}
}

// listOnGnoswapWithFunding is the full auto path: pull inventory from caller if needed,
// CreatePool+Mint, reimburse LP ugnot / refund on failure.
func listOnGnoswapWithFunding(cur realm, l *Launch, raisedUgnot, remainingTokens int64) bool {
	fund := prepareCallerListFunding(cur, l, raisedUgnot)
	if !fund.ok {
		return false
	}
	ok := tryListOnGnoswap(cur, l, raisedUgnot, remainingTokens)
	if ok {
		settleCallerListFunding(cur, fund)
		if fund.pulledLpWugnot > 0 || fund.pulledFeeWugnot > 0 || fund.pulledGns > 0 {
			chain.Emit("ListFunding",
				"id", l.ID,
				"caller", fund.caller.String(),
				"lpWugnot", strconv.FormatInt(fund.pulledLpWugnot, 10),
				"feeWugnot", strconv.FormatInt(fund.pulledFeeWugnot, 10),
				"gns", strconv.FormatInt(fund.pulledGns, 10),
			)
		}
		return true
	}
	refundCallerListFunding(cur, fund)
	return false
}

// listNeedOf: poolU|wHave|wNeedLp|gnsHave|gnsNeed|feeGns|feeWugnotBudget|padAddr
func listNeedOf(l *Launch) string {
	poolU := int64(0)
	if l != nil && l.Status == StatusGraduated && !l.GnoswapListed {
		poolU = l.PoolUgnot
	}
	padA := padAddr
	wHave := wugnot.BalanceOf(padA)
	gnsHave := gns.BalanceOf(padA)
	feeGns := gnspool.GetPoolCreationFee()
	if feeGns <= 0 {
		feeGns = 100_000_000
	}
	wNeed := poolU - wHave
	if wNeed < 0 {
		wNeed = 0
	}
	gNeed := feeGns - gnsHave
	if gNeed < 0 {
		gNeed = 0
	}
	feeBud := listFeeWugnotPull()
	// If GNS already covered, fee WUGNOT budget need is 0 for the wizard.
	if gNeed == 0 {
		feeBud = 0
	} else if wHave > poolU {
		// Existing surplus reduces fee budget to pull
		surp := wHave - poolU
		if surp >= feeBud {
			feeBud = 0
		} else {
			feeBud = feeBud - surp
		}
	}
	return strconv.FormatInt(poolU, 10) + "|" +
		strconv.FormatInt(wHave, 10) + "|" +
		strconv.FormatInt(wNeed, 10) + "|" +
		strconv.FormatInt(gnsHave, 10) + "|" +
		strconv.FormatInt(gNeed, 10) + "|" +
		strconv.FormatInt(feeGns, 10) + "|" +
		strconv.FormatInt(feeBud, 10) + "|" +
		padA.String()
}

// ListNeed is the public query for the Token "list on Gnoswap" wizard.
func ListNeed(id string) string {
	return listNeedOf(mustLaunch(id))
}

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
