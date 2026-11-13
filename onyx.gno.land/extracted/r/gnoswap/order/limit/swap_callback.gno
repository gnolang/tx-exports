package limit

import (
	"errors"

	prbac "gno.land/p/gnoswap/rbac/v1"
	"gno.land/r/gnoswap/access/v1"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/pool"
)

// NewSwapCallback binds payment to this proxy's custody, the order's input
// token and its input budget. Only code already executing in the proxy's current
// realm context can create it. The closure is declared here so pool callbacks
// retain proxy custody rather than paying from an implementation realm.
func NewSwapCallback(_ int, rlm realm, tokenIn string, zeroForOne bool, maxAmountIn int64) func(cur realm, amount0Delta, amount1Delta int64, marker *pool.CallbackMarker) error {
	if !rlm.IsCurrent() || rlm.Address() != Address() || tokenIn == "" || maxAmountIn <= 0 {
		panic(errInvalidSwapCallback)
	}

	poolAddress := access.MustGetAddress(prbac.ROLE_POOL.String())
	remaining := maxAmountIn

	return func(cur realm, amount0Delta, amount1Delta int64, marker *pool.CallbackMarker) error {
		if !cur.IsCurrent() || cur.Address() != Address() || cur.Previous().Address() != poolAddress || marker == nil {
			return errors.New(errInvalidSwapCallback)
		}

		input, output := amount0Delta, amount1Delta
		if !zeroForOne {
			input, output = amount1Delta, amount0Delta
		}

		if input <= 0 || output > 0 || input > remaining {
			return errors.New(errInvalidSwapCallback)
		}

		remaining -= input

		return common.Transfer(0, cur, tokenIn, poolAddress, input)
	}
}
