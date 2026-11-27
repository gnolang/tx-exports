package tributary_demo

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/ufmt/v0"
	rtrib "gno.land/r/g196fz02krdlf6fc7a7p2w8e4rkywepwn5c9nh63/tributary"
)

const (
	denom         = "ugnot"
	protocolFeeBP = 1000 // 10% of every demo trade automatically cascades upstream via Tributary
)

var (
	tradeCount     int64
	totalVolume    int64
	totalStreamed  int64
	targetNodeID   = "swap-ui"
)

// SwapDemo simulates a user executing a swap with attached ugnot.
// 10% of the attached ugnot is automatically streamed cross-realm into Tributary's
// diamond dependency DAG via DepositWithBanker using this realm's canonical RealmSend banker,
// while 90% is immediately refunded to the caller (zero funds trapped).
func SwapDemo(cur realm, memo string) (streamed int64) {
	if !cur.Previous().IsUserCall() {
		panic("tributary_demo: direct user call required")
	}
	sent := unsafe.OriginSend().AmountOf(denom)
	if sent < 100 {
		panic("tributary_demo: attach at least 100 ugnot")
	}

	caller := cur.Previous().Address()
	fee := (sent * protocolFeeBP) / 10000
	refund := sent - fee

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if fee > 0 {
		// Cross-realm composable revenue streaming into Tributary DAG!
		rtrib.DepositWithBanker(cross(cur), targetNodeID, "SwapDemo: "+memo, b, fee)
	}
	if refund > 0 {
		b.SendCoins(cur.Address(), caller, chain.NewCoins(chain.NewCoin(denom, refund)))
	}

	tradeCount++
	totalVolume += sent
	totalStreamed += fee

	chain.Emit("DemoSwapStreamed",
		"trader", caller.String(),
		"volume", strconv.FormatInt(sent, 10),
		"streamed", strconv.FormatInt(fee, 10),
		"targetNode", targetNodeID,
	)
	return fee
}

func Render(path string) string {
	return ufmt.Sprintf(
		"# Tributary Composable Consumer Demo (`r/tributary_demo`)\n\n"+
			"This minimal realm proves **5-line cross-realm composability**: every `SwapDemo` call automatically streams **10%%** of attached `ugnot` into `r/tributary` node `%s` via `DepositWithBanker` using a canonical `BankerTypeRealmSend` banker.\n\n"+
			"| Metric | Value |\n|---|---|\n"+
			"| Demo Trades Executed | **%d** |\n"+
			"| Total Volume Processed | `%d ugnot` |\n"+
			"| Auto-Streamed to Upstream OSS DAG | **%d ugnot** |\n\n"+
			"Inspect the live waterfall target: [Tributary `swap-ui` DAG](/r/g196fz02krdlf6fc7a7p2w8e4rkywepwn5c9nh63/tributary:node/%s)\n",
		targetNodeID, tradeCount, totalVolume, totalStreamed, targetNodeID,
	)
}
