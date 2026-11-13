package impl

import (
	"math"
	"strconv"

	plimit "gno.land/p/gnoswap/order/limit/v0"
	u256 "gno.land/p/gnoswap/uint256/v1"
)

// The default bounds exclude the two TickMath endpoints.
const (
	minSwapSqrtPrice = "4295128740"
	maxSwapSqrtPrice = "1461446703485210103287273052203988822378723970341"
)

func orderPriceLimit(price string, zeroForOne bool) (string, bool, error) {
	value, err := u256.FromDecimal(price)
	if err != nil {
		return "", false, makeErrorWithDetails(errInvalidPriceLimit, price)
	}

	if !value.IsZero() {
		return price, false, nil
	}

	if zeroForOne {
		return minSwapSqrtPrice, true, nil
	}

	return maxSwapSqrtPrice, true, nil
}

func poolSwapAmounts(amount0, amount1 string, zeroForOne bool) (int64, int64, error) {
	input, output := amount0, amount1
	if !zeroForOne {
		input, output = amount1, amount0
	}

	actualInput, err := strconv.ParseInt(input, 10, 64)
	if err != nil || actualInput <= 0 {
		return 0, 0, plimit.ErrInvalidFillAmount
	}

	outputDelta, err := strconv.ParseInt(output, 10, 64)
	if err != nil || outputDelta == math.MinInt64 {
		return 0, 0, plimit.ErrAmountOverflow
	}

	if outputDelta >= 0 {
		return 0, 0, plimit.ErrInsufficientOutput
	}

	return actualInput, -outputDelta, nil
}
