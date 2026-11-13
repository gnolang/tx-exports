package impl

import (
	"strconv"

	pdca "gno.land/p/gnoswap/order/dca/v0"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/common"
	dca "gno.land/r/gnoswap/order/dca"
	"gno.land/r/gnoswap/pool"
)

// swapDirection returns the pool direction of selling inputToken for
// outputToken and the pool's token order.
func swapDirection(inputToken string, outputToken string) (zeroForOne bool, token0 string, token1 string) {
	if inputToken < outputToken {
		return true, inputToken, outputToken
	}

	return false, outputToken, inputToken
}

// swapExactIn sells amountIn on the pair's pool of fee tier fee, down to
// sqrtPriceLimitX96 (see calculateSqrtPriceLimitX96), and returns the output
// received by the escrow. A pool that reaches the limit before selling the
// whole input fails the round.
//
// The pool sends the output first, then calls the escrow's swap callback,
// which pays the input from the escrow without any allowance (see
// dca.NewSwapCallback). The pool result is checked against the escrow's
// balance changes: the whole input must be sold, and the output must reach
// amountOutMin (0 disables it).
func swapExactIn(_ int, rlm realm, group *pdca.Group, fee uint32, sqrtPriceLimitX96 string, amountIn int64, amountOutMin int64) (int64, error) {
	escrowAddress := rlm.Address()
	inputToken := group.InputToken()
	outputToken := group.OutputToken()
	zeroForOne, token0, token1 := swapDirection(inputToken, outputToken)

	inputBalanceBefore := common.BalanceOf(inputToken, escrowAddress)
	outputBalanceBefore := common.BalanceOf(outputToken, escrowAddress)

	amount0, amount1 := pool.Swap(
		cross(rlm),
		token0,
		token1,
		fee,
		escrowAddress,
		zeroForOne,
		strconv.FormatInt(amountIn, 10),
		sqrtPriceLimitX96,
		dca.NewSwapCallback(0, rlm, inputToken, zeroForOne, amountIn),
	)

	// Pool deltas: positive is owed to the pool, negative is sent out.
	poolAmountIn, poolAmountOut := amount0, amount1
	if !zeroForOne {
		poolAmountIn, poolAmountOut = amount1, amount0
	}

	spentAmount := inputBalanceBefore - common.BalanceOf(inputToken, escrowAddress)
	receivedAmount := common.BalanceOf(outputToken, escrowAddress) - outputBalanceBefore

	poolInDelta, err := strconv.ParseInt(poolAmountIn, 10, 64)
	if err != nil || spentAmount != amountIn || poolInDelta != amountIn {
		return 0, makeErrorWithDetails(
			errSwapMismatch,
			ufmt.Sprintf("input spent(%d) pool(%s) expected(%d)", spentAmount, poolAmountIn, amountIn),
		)
	}

	poolOutDelta, err := strconv.ParseInt(poolAmountOut, 10, 64)
	if err != nil || receivedAmount < 0 || poolOutDelta != -receivedAmount {
		return 0, makeErrorWithDetails(
			errSwapMismatch,
			ufmt.Sprintf("output received(%d) pool(%s)", receivedAmount, poolAmountOut),
		)
	}

	if receivedAmount < amountOutMin {
		return 0, makeErrorWithDetails(
			errInsufficientSwapOutput,
			ufmt.Sprintf("output(%d) amountOutMin(%d)", receivedAmount, amountOutMin),
		)
	}

	return receivedAmount, nil
}
