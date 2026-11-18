package dca

import (
	prbac "gno.land/p/gnoswap/rbac/v1"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/access/v1"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/pool"
)

// NewSwapCallback returns the callback of one round's pool.Swap. It pays the
// pool the round input, at most maxAmountIn of tokenIn, from the escrow.
//
// The callback is declared in this realm, so it transfers as the escrow
// itself: the escrow never grants an allowance for a swap. That makes the
// callback a payment capability, so it is guarded on creation and on use:
//
//   - only the escrow's own current realm can create one, so only code the
//     proxy hands its realm to (the active implementation) can;
//   - only the pool can invoke it (cur.Previous()); the pool's swap lock
//     admits no other swap while a round's swap runs;
//   - it pays only while a round is executing, once, and only an exact-input
//     delta of the sold token: positive input, no positive output, at most
//     maxAmountIn.
//
// zeroForOne is the swap direction: it selects which pool delta is tokenIn.
func NewSwapCallback(_ int, rlm realm, tokenIn string, zeroForOne bool, maxAmountIn int64) func(cur realm, amount0Delta, amount1Delta int64, _ *pool.CallbackMarker) error {
	if !rlm.IsCurrent() || rlm.Address() != Address() {
		panic(ErrSpoofedRealm)
	}

	if maxAmountIn <= 0 {
		panic(makeErrorWithDetails(ErrInvalidSwapCallback, ufmt.Sprintf("maxAmountIn(%d)", maxAmountIn)).Error())
	}

	poolAddress := access.MustGetAddress(prbac.ROLE_POOL.String())
	paid := false

	// The marker is not checked: pool.NewCallbackMarker is public, so it
	// proves nothing about the caller. The caller check below does.
	return func(cur realm, amount0Delta, amount1Delta int64, _ *pool.CallbackMarker) error {
		if cur.Previous().Address() != poolAddress {
			return makeErrorWithDetails(ErrInvalidSwapCallback, "caller is not the pool")
		}

		if paid || !NewDCAOrderStore(kvStore).IsExecuting() {
			return makeErrorWithDetails(ErrInvalidSwapCallback, "no round swap awaits payment")
		}

		input, output := amount0Delta, amount1Delta
		if !zeroForOne {
			input, output = amount1Delta, amount0Delta
		}

		if input <= 0 || output > 0 || input > maxAmountIn {
			return makeErrorWithDetails(
				ErrInvalidSwapCallback,
				ufmt.Sprintf("input(%d) output(%d) maxAmountIn(%d)", input, output, maxAmountIn),
			)
		}

		paid = true

		return common.Transfer(0, cur, tokenIn, poolAddress, input)
	}
}
