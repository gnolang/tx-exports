// Package dexprobe is a one-shot feasibility probe: it exercises every GnoSwap
// primitive an on-chain order engine (DCA / limit / stop-loss, keeper-driven,
// non-custodial or vault-funded) would ever need, so the real build is derisked
// in a single deploy. Each exported fn answers one unknown; a harness drives the
// multi-tx cases. Throwaway test realm — no product code here.
package dexprobe

import (
	"strconv"
	"time"

	"chain"
	"chain/banker"

	"gno.land/p/nt/avl/v0"

	"gno.land/r/gnoland/wugnot"
	"gno.land/r/gnoswap/gns"
	"gno.land/r/gnoswap/pool"
	"gno.land/r/gnoswap/router"
)

const (
	WUG  = "gno.land/r/gnoland/wugnot"
	GNS  = "gno.land/r/gnoswap/gns"
	USDC = "gno.land/r/gnoswap/test_token/test_usdc"
	DAI  = "gno.land/r/gnoswap/test_token/test_dai"

	poolWG    = "gno.land/r/gnoland/wugnot:gno.land/r/gnoswap/gns:3000" // canonical, for pool reads
	routeBuy  = poolWG                                                  // WG -> GNS
	routeSell = "gno.land/r/gnoswap/gns:gno.land/r/gnoland/wugnot:3000" // GNS -> WG
	// 2-hop, no direct WG/DAI pool: WG -> USDC -> DAI
	routeMulti = "gno.land/r/gnoland/wugnot:gno.land/r/gnoswap/test_token/test_usdc:3000*POOL*gno.land/r/gnoswap/test_token/test_usdc:gno.land/r/gnoswap/test_token/test_dai:3000"
)

var routerAddr = address("g1vc883gshu5z7ytk5cdynhc8c2dh67pdp4cszkp")

var (
	vault   avl.Tree // owner -> int64 wugnot deposited (pre-funded custody model)
	counter int      // for the fail-atomicity probe
)

// ---- helpers ----
func i64(n int64) string { return strconv.FormatInt(n, 10) }
func atoi(s string) int64 { n, _ := strconv.ParseInt(s, 10, 64); return n }
func dl() int64           { return time.Now().Unix() + 300 }

// Fund lets the harness deposit native ugnot into this realm (for tip/native-send probes).
func Fund(cur realm) {}

// ============================================================ PRICE READS ====

func SpotTick() int32       { return pool.GetSlot0Tick(poolWG) }
func SpotSqrtPrice() string { return pool.GetSlot0SqrtPriceX96(poolWG) }

// TwapProbe answers the #1 unknown: does a manipulation-resistant TWAP work?
// Returns "tick=<t> liq=<l> err=<e>". On un-warmed pools err is non-nil.
func TwapProbe(secondsAgo uint32) string {
	t, l, err := pool.GetTWAP(poolWG, secondsAgo)
	e := "nil"
	if err != nil {
		e = err.Error()
	}
	return "tick=" + i32(t) + " liq=" + l + " err=" + e
}

// Cardinality reports the pool's observation-buffer size (1 = un-warmed → no TWAP).
func Cardinality() string {
	os, err := pool.GetObservationState(poolWG)
	if err != nil {
		return "err=" + err.Error()
	}
	return "card=" + u16(os.Cardinality()) + " next=" + u16(os.CardinalityNext())
}

// GrowCardinality warms the TWAP buffer (Uniswap-v3 style). Crossing fn.
func GrowCardinality(cur realm, cardNext uint16) {
	pool.IncreaseObservationCardinalityNext(cross(cur), WUG, GNS, 3000, cardNext)
	chain.Emit("GrewCardinality", "next", u16(cardNext))
}

// DryQuote calls GnoSwap's read-only quote FROM inside a realm (the slippage-floor
// dependency). Returns the expected GNS out for amountIn wugnot.
func DryQuote(amountIn int64) string {
	_, out, ok := router.DrySwapRoute(WUG, GNS, i64(amountIn), "EXACT_IN", routeBuy, "100", "1")
	return "out=" + out + " ok=" + boolS(ok)
}

// BestTier scans the fee tiers for the deepest pool of a pair (tier-selection).
func BestTier(a, b string) string {
	best := uint32(0)
	bestLiq := int64(-1)
	for _, fee := range []uint32{100, 500, 3000, 10000} {
		for _, pp := range []string{a + ":" + b + ":" + u32(fee), b + ":" + a + ":" + u32(fee)} {
			if pool.ExistsPoolPath(pp) {
				liq := atoi(pool.GetLiquidity(pp))
				if liq > bestLiq {
					bestLiq, best = liq, fee
				}
			}
		}
	}
	return "bestFee=" + u32(best) + " liq=" + i64(bestLiq)
}

// ============================================================== SWAPS ========
// All pull the caller's input via allowance, swap as payer/recipient, forward output.

// BuyGns: WG -> GNS (baseline, allowance-funded). Returns GNS out.
func BuyGns(cur realm, amountIn, minOut int64) int64 {
	u, self := cur.Previous().Address(), cur.Address()
	wugnot.TransferFrom(cross(cur), u, self, amountIn)
	wugnot.Approve(cross(cur), routerAddr, amountIn)
	b := gns.BalanceOf(self)
	router.ExactInSingleSwapRoute(cross(cur), WUG, GNS, i64(amountIn), routeBuy, i64(minOut), "0", dl(), "")
	out := gns.BalanceOf(self) - b
	gns.Transfer(cross(cur), u, out)
	return out
}

// SellGns: GNS -> WG (proves the SELL side). Returns wugnot out.
func SellGns(cur realm, amountGns, minOut int64) int64 {
	u, self := cur.Previous().Address(), cur.Address()
	gns.TransferFrom(cross(cur), u, self, amountGns)
	gns.Approve(cross(cur), routerAddr, amountGns)
	b := wugnot.BalanceOf(self)
	router.ExactInSingleSwapRoute(cross(cur), GNS, WUG, i64(amountGns), routeSell, i64(minOut), "0", dl(), "")
	out := wugnot.BalanceOf(self) - b
	wugnot.Transfer(cross(cur), u, out)
	return out
}

// SellGnsToNative: sell GNS, unwrap wugnot -> native ugnot, deliver via banker.
func SellGnsToNative(cur realm, amountGns, minOut int64) int64 {
	u, self := cur.Previous().Address(), cur.Address()
	gns.TransferFrom(cross(cur), u, self, amountGns)
	gns.Approve(cross(cur), routerAddr, amountGns)
	b := wugnot.BalanceOf(self)
	router.ExactInSingleSwapRoute(cross(cur), GNS, WUG, i64(amountGns), routeSell, i64(minOut), "0", dl(), "")
	out := wugnot.BalanceOf(self) - b
	wugnot.Withdraw(cross(cur), out) // burn realm's wugnot -> native ugnot to realm
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(self, u, chain.Coins{chain.NewCoin("ugnot", out)})
	return out
}

// BuyExactGns: ExactOut — buy exactly amountOut GNS, spending <= amountInMax wugnot,
// refunding the unused wugnot. Returns actual wugnot spent.
func BuyExactGns(cur realm, amountOut, amountInMax int64) int64 {
	u, self := cur.Previous().Address(), cur.Address()
	wugnot.TransferFrom(cross(cur), u, self, amountInMax)
	wugnot.Approve(cross(cur), routerAddr, amountInMax)
	gb := gns.BalanceOf(self)
	inStr, _ := router.ExactOutSingleSwapRoute(cross(cur), WUG, GNS, i64(amountOut), routeBuy, i64(amountInMax), "0", dl(), "")
	gns.Transfer(cross(cur), u, gns.BalanceOf(self)-gb) // deliver GNS
	spent := atoi(inStr)
	if refund := amountInMax - spent; refund > 0 {
		wugnot.Transfer(cross(cur), u, refund) // refund unused wugnot
	}
	return spent
}

// MultiHopBuy: WG -> USDC -> DAI (2 hops). Returns DAI out (string, from the router).
// DAI stays in the realm (no DAI import needed to prove multi-hop works).
func MultiHopBuy(cur realm, amountIn, minOut int64) string {
	u, self := cur.Previous().Address(), cur.Address()
	wugnot.TransferFrom(cross(cur), u, self, amountIn)
	wugnot.Approve(cross(cur), routerAddr, amountIn)
	_, out := router.ExactInSwapRoute(cross(cur), WUG, DAI, i64(amountIn), routeMulti, "100", i64(minOut), dl(), "")
	return out
}

// FloorBuy: the on-chain slippage-floor design. Quote GnoSwap for THIS size, derive
// minOut = expected*(1-maxSlippageBps) ON-CHAIN, then swap. Keeper can't set the floor.
func FloorBuy(cur realm, amountIn, maxSlippageBps int64) int64 {
	u, self := cur.Previous().Address(), cur.Address()
	_, expStr, ok := router.DrySwapRoute(WUG, GNS, i64(amountIn), "EXACT_IN", routeBuy, "100", "1")
	if !ok {
		panic("dry quote unfillable")
	}
	minOut := atoi(expStr) * (10000 - maxSlippageBps) / 10000
	wugnot.TransferFrom(cross(cur), u, self, amountIn)
	wugnot.Approve(cross(cur), routerAddr, amountIn)
	b := gns.BalanceOf(self)
	router.ExactInSingleSwapRoute(cross(cur), WUG, GNS, i64(amountIn), routeBuy, i64(minOut), "0", dl(), "")
	out := gns.BalanceOf(self) - b
	gns.Transfer(cross(cur), u, out)
	chain.Emit("FloorBuy", "expected", expStr, "minOut", i64(minOut), "got", i64(out))
	return out
}

// ========================================================= KEEPER ECON =======

// TipKeeper pays the caller `amount` ugnot from the realm's native balance (the
// permissionless-keeper payment mechanic). Realm must be pre-Funded.
func TipKeeper(cur realm, amount int64) {
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), cur.Previous().Address(), chain.Coins{chain.NewCoin("ugnot", amount)})
	chain.Emit("TipPaid", "keeper", cur.Previous().Address().String(), "amount", i64(amount))
}

// FeeSkimBuy buys GNS, then skims feeBps of the output to `treasury` (revenue model).
func FeeSkimBuy(cur realm, amountIn, feeBps int64, treasury address) int64 {
	u, self := cur.Previous().Address(), cur.Address()
	wugnot.TransferFrom(cross(cur), u, self, amountIn)
	wugnot.Approve(cross(cur), routerAddr, amountIn)
	b := gns.BalanceOf(self)
	router.ExactInSingleSwapRoute(cross(cur), WUG, GNS, i64(amountIn), routeBuy, "1", "0", dl(), "")
	out := gns.BalanceOf(self) - b
	fee := out * feeBps / 10000
	if fee > 0 {
		gns.Transfer(cross(cur), treasury, fee)
	}
	gns.Transfer(cross(cur), u, out-fee)
	return fee
}

// ============================================================ VAULT ==========
// Pre-funded custody model: owner deposits wugnot; keeper draws per fill (no allowance).

func VaultDeposit(cur realm, amount int64) {
	u, self := cur.Previous().Address(), cur.Address()
	wugnot.TransferFrom(cross(cur), u, self, amount)
	vault.Set(u.String(), vaultBal(u)+amount)
	chain.Emit("VaultDeposit", "owner", u.String(), "amount", i64(amount))
}

func VaultBalance(owner address) int64 { return vaultBal(owner) }

// VaultSwapBuy: keeper-callable, draws from the owner's vault balance (not allowance),
// swaps, forwards GNS to owner. `owner` is an arg because the keeper (not owner) calls.
func VaultSwapBuy(cur realm, owner address, amountIn, minOut int64) int64 {
	self := cur.Address()
	bal := vaultBal(owner)
	if bal < amountIn {
		panic("insufficient vault balance")
	}
	vault.Set(owner.String(), bal-amountIn) // STATE-BEFORE-SEND
	wugnot.Approve(cross(cur), routerAddr, amountIn)
	b := gns.BalanceOf(self)
	router.ExactInSingleSwapRoute(cross(cur), WUG, GNS, i64(amountIn), routeBuy, i64(minOut), "0", dl(), "")
	out := gns.BalanceOf(self) - b
	gns.Transfer(cross(cur), owner, out)
	return out
}

func VaultWithdraw(cur realm, amount int64) {
	u := cur.Previous().Address()
	bal := vaultBal(u)
	if bal < amount {
		panic("insufficient vault balance")
	}
	vault.Set(u.String(), bal-amount) // STATE-BEFORE-SEND
	wugnot.Transfer(cross(cur), u, amount)
}

func vaultBal(owner address) int64 {
	v, ok := vault.Get(owner.String())
	if !ok {
		return 0
	}
	return v.(int64)
}

// ======================================================= FAIL ATOMICITY ======

func Counter() int { return counter }

// FailAtomic bumps the counter then forces a swap revert (impossible minOut). The whole
// tx must revert → Counter() stays unchanged, proving state rolls back on a failed fill.
func FailAtomic(cur realm, amountIn int64) {
	counter++
	u, self := cur.Previous().Address(), cur.Address()
	wugnot.TransferFrom(cross(cur), u, self, amountIn)
	wugnot.Approve(cross(cur), routerAddr, amountIn)
	router.ExactInSingleSwapRoute(cross(cur), WUG, GNS, i64(amountIn), routeBuy, i64(amountIn*1000000), "0", dl(), "")
}

// ---- fmt helpers ----
func i32(n int32) string  { return strconv.FormatInt(int64(n), 10) }
func u16(n uint16) string { return strconv.FormatUint(uint64(n), 10) }
func u32(n uint32) string { return strconv.FormatUint(uint64(n), 10) }
func boolS(b bool) string { if b { return "true" }; return "false" }

func Render(_ string) string {
	return "# dexprobe (feasibility probe)\n\nLive tick: " + i32(SpotTick()) +
		"\nCardinality: " + Cardinality() + "\nCounter: " + strconv.Itoa(counter) + "\n"
}
