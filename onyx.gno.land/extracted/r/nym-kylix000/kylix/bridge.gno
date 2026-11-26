package kylix

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nym-kylix000/ring/v0"
	"gno.land/r/gnoswap/pool"
	"gno.land/r/gnoswap/router"
	"gno.land/r/nt/grc20reg/v0"
)

// The GnoSwap bridge (decision 6). A ring may contain one hop that gives
// token A to someone who wants token B; Kylix swaps A for B on GnoSwap in
// the middle of the settlement. See docs/research/gnoswap-bridge.md.
//
// The input passes through Kylix's own sub-address cur.Sub("settle") for
// the length of one swap, because the router pays out to whoever called it.
// It is empty again before SettleRing returns.

const (
	// routerPath is the router proxy. The input allowance must be on this
	// address: the router pulls the input with its own RealmTeller.
	routerPath = "gno.land/r/gnoswap/router"
	settlePath = "settle"
)

var feeTiers = [4]uint32{100, 500, 3000, 10000}

// bridgeFee picks the fee tier SettleRing swaps through: among the pools
// that exist for the pair and hold some of the output token, the one holding
// the most of it. It returns false when there is none. It only reads (pool
// getters run without crossing and have no realm value with which to call
// back).
//
// A pool's balance counts liquidity at every price, so it is a poor guide
// when a pair has several pools: anyone can add liquidity that sits far from
// the current price and make this choose a pool that cannot pay the
// receiver's minimum, which aborts the ring. The receiver never gets less
// than their minimum either way. SettleRingVia lets the settler name the
// pool; this automatic choice is a convenience for pairs with one pool.
//
// No price quote is taken here: a DrySwapRoute costs about 20M gas.
func bridgeFee(keyIn, keyOut string) (uint32, bool) {
	best, found := uint32(0), false
	var bestReserve int64
	outIsToken1 := strings.Compare(keyOut, keyIn) > 0
	for _, fee := range feeTiers {
		path := pool.GetPoolPath(keyIn, keyOut, fee)
		if !pool.ExistsPoolPath(path) {
			continue
		}
		b0, b1, err := pool.GetBalances(path)
		if err != nil {
			continue
		}
		reserve := b0
		if outIsToken1 {
			reserve = b1
		}
		if reserve > bestReserve {
			best, bestReserve, found = fee, reserve, true
		}
	}
	return best, found
}

// poolExists reports whether a GnoSwap pool exists for the pair at fee.
func poolExists(keyIn, keyOut string, fee uint32) bool {
	return pool.ExistsPoolPath(pool.GetPoolPath(keyIn, keyOut, fee))
}

// isFeeTier reports whether fee is one of GnoSwap's fee tiers.
func isFeeTier(fee uint32) bool {
	for _, f := range feeTiers {
		if f == fee {
			return true
		}
	}
	return false
}

// bridgeHop settles a bridged hop: pull the offer's input through its slot
// into the settle sub-address, swap it as that sub-address, check that the
// whole input was used and that the output meets the receiver's minimum,
// and forward all of the output to the receiver. slot and settle are
// sub-realm tokens minted from SettleRing's cur; this is called without
// crossing so both stay current.
func bridgeHop(_ int, slot, settle realm, i int, o *Offer, h ring.Hop, to address, fee uint32) {
	keyIn, keyOut := h.Asset.Key, h.Want.Key
	amountIn, wantMin := h.Asset.Amount, h.Want.Amount
	settleAddr := settle.Address()
	routerAddr := chain.PackageAddress(routerPath)
	route := keyIn + ":" + keyOut + ":" + strconv.FormatUint(uint64(fee), 10)

	grc20reg.TransferFrom(0, slot, keyIn, o.Owner, settleAddr, amountIn)
	grc20reg.Approve(0, settle, keyIn, routerAddr, amountIn)
	usedStr, gotStr := router.ExactInSingleSwapRoute(cross(settle),
		keyIn, keyOut, i64(amountIn), route, i64(wantMin), "0", time.Now().Unix(), "")

	used, err := strconv.ParseInt(usedStr, 10, 64)
	if err != nil || used != amountIn {
		panic(legMsg(i, o.ID, "swap used "+usedStr+" of "+i64(amountIn)+"; a leg gives its whole amount"))
	}
	// The router spent exactly the allowance, which deletes it. Setting it to
	// 0 again would store a zero entry, so check instead of resetting.
	if left := tokenOf(keyIn).Allowance(settleAddr, routerAddr); left != 0 {
		panic(legMsg(i, o.ID, "router allowance left after the swap: "+i64(left)))
	}
	got, err := strconv.ParseInt(gotStr, 10, 64)
	if err != nil || got <= 0 || got < wantMin {
		panic(legMsg(i, o.ID, "swap returned "+gotStr+" of "+keyOut+", receiver wants at least "+i64(wantMin)))
	}
	grc20reg.Transfer(0, settle, keyOut, to, got)
}

// SettleAddress is the sub-address a bridged swap passes through. It holds
// nothing between transactions.
func SettleAddress() address { return chain.DerivePkgSubAddr(selfPath, settlePath) }
