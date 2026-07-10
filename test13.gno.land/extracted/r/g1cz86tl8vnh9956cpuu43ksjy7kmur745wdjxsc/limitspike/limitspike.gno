// Package limitspike is a throwaway spike proving the make-or-break leg of a
// GnoPulse limit-order product: that a realm can (a) read GnoSwap's live pool
// tick on-chain to GATE execution, and (b) execute a swap on GnoSwap *on a
// user's behalf* — the realm holds the tokens (pulled from the user via GRC20
// allowance), is the swap payer, receives the output, and forwards it back.
//
// Confirmed against GnoSwap on test-13:
//   - router debits the immediate calling realm (PreviousRealm), not the EOA,
//     so delegated execution works;
//   - native ugnot is rejected on the swap tx — the GNOT side must be wugnot;
//   - the GRC20 allowance spender for the swap is the router role address.
package limitspike

import (
	"strconv"
	"time"

	"chain"

	"gno.land/r/gnoland/wugnot"
	"gno.land/r/gnoswap/gns"
	"gno.land/r/gnoswap/pool"
	"gno.land/r/gnoswap/router"
)

const (
	inTok    = "gno.land/r/gnoland/wugnot"
	outTok   = "gno.land/r/gnoswap/gns"
	poolPath = "gno.land/r/gnoland/wugnot:gno.land/r/gnoswap/gns:3000" // 0.3% tier, deepest GNOT/GNS pool
	routeArr = poolPath
)

// routerAddr is the GnoSwap router role address — the spender this realm must
// Approve on its wugnot before the swap (the router does the TransferFrom).
var routerAddr = address("g1vc883gshu5z7ytk5cdynhc8c2dh67pdp4cszkp")

// Tick returns the live GnoSwap pool tick — the trigger signal. Read-only.
func Tick() int32 {
	return pool.GetSlot0Tick(poolPath)
}

// Execute runs one delegated limit swap of `amountIn` wugnot -> GNS for the caller.
//
// Preconditions (set by the caller in prior txs):
//   - caller holds >= amountIn wugnot (wrap ugnot via wugnot.Deposit first);
//   - caller has Approve'd THIS realm as spender for >= amountIn wugnot.
//
// The limit gate: execution is refused unless the live pool tick >= minTick.
// (minTick is the on-chain, MEV-safe trigger — the realm re-checks it itself,
// so a keeper poking this function can never force an off-limit fill.)
//
// minOut is the slippage floor (amountOutMin) passed to GnoSwap.
// Returns (tickAtExecution, gnsForwardedToCaller).
func Execute(cur realm, amountIn int64, minTick int32, minOut int64) (int32, int64) {
	if !cur.IsCurrent() {
		panic("spoofed realm")
	}
	if amountIn <= 0 {
		panic("amountIn must be > 0")
	}
	user := cur.Previous().Address()
	self := cur.Address()

	// 1) LIMIT GATE — the whole point. Read the live pool tick and refuse if
	//    the trigger price hasn't been reached. Cheap int32 compare, no oracle.
	tick := pool.GetSlot0Tick(poolPath)
	if tick < minTick {
		panic("limit not reached: tick " + i32(tick) + " < minTick " + i32(minTick))
	}

	// 2) Pull the user's wugnot into this realm (needs prior Approve to us).
	wugnot.TransferFrom(cross(cur), user, self, amountIn)

	// 3) Approve the GnoSwap router to spend this realm's wugnot.
	wugnot.Approve(cross(cur), routerAddr, amountIn)

	// 4) Swap wugnot -> GNS. GnoSwap pulls wugnot FROM this realm and sends GNS
	//    TO this realm (payer/recipient = PreviousRealm = us). Measure by delta
	//    rather than trusting the returned string.
	before := gns.BalanceOf(self)
	router.ExactInSingleSwapRoute(
		cross(cur),
		inTok, outTok,
		i64(amountIn),   // amountIn
		routeArr,        // single-hop route
		i64(minOut),     // amountOutMin (slippage floor)
		"0",             // sqrtPriceLimitX96 = no price limit
		time.Now().Unix()+300, // deadline: block-time unix + 5 min
		"",              // referrer
	)
	out := gns.BalanceOf(self) - before

	// 5) Forward the received GNS back to the user.
	if out > 0 {
		gns.Transfer(cross(cur), user, out)
	}

	chain.Emit("LimitSwapExecuted",
		"user", user.String(),
		"tick", i32(tick),
		"amountIn", i64(amountIn),
		"gnsOut", i64(out),
	)
	return tick, out
}

func Render(_ string) string {
	return "# limitspike\n\nSpike: realm-delegated GnoSwap limit swap (wugnot->GNS). Live tick: " +
		i32(Tick()) + "\n"
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }
func i32(n int32) string { return strconv.FormatInt(int64(n), 10) }
