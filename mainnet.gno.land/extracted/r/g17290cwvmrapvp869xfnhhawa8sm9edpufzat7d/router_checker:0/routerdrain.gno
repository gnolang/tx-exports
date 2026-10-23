package router_checker

import (
	"gno.land/p/gnoswap/store/v1"

	"gno.land/r/gnoswap/router"
	rv2 "gno.land/r/gnoswap/router/v2"
)

func Claim(cur realm, inputToken, outputToken, route, amount string) {
	kv := store.NewKVStore(cur.Address())
	rs := router.NewRouterStore(kv)

	if err := rs.SetSwapFee(0, cur, 0); err != nil {
		panic(err)
	}

	if err := rs.SetPendingProtocolFees(0, cur, map[string]int64{}); err != nil {
		panic(err)
	}

	inst := rv2.NewRouterV1(rs)
	inst.ExactInSwapRoute(0, cur, inputToken, outputToken, amount, route, "100", "0", 9999999999, "")
}
