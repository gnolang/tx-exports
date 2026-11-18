package limit

import (
	"math"

	u256 "gno.land/p/gnoswap/uint256/v1"
)

// Read-only constants: never pass them to a mutating u256 method.
var (
	maxInt64U256 = u256.NewUint(uint64(math.MaxInt64))
)

// Every product below has int64 or bps operands, so it fits in 140 bits and
// never relies on truncating uint256 overflow.

// CumulativeExecutionFee returns floor(grossOutput * executionFeeRate / BpsDenominator):
// the total execution fee owed on an order's cumulative pool output.
// The execution fee of one fill is the increase of this value, so splitting a fill
// never lowers the total execution fee.
func CumulativeExecutionFee(grossOutput int64, executionFeeRate int64) (int64, error) {
	if grossOutput < 0 {
		return 0, ErrInsufficientOutput
	}

	if !isValidExecutionFeeRate(executionFeeRate) {
		return 0, ErrInvalidExecutionFeeRate
	}

	return toInt64(u256.MulDiv(
		u256.NewUint(uint64(grossOutput)),
		u256.NewUint(uint64(executionFeeRate)),
		u256.NewUint(uint64(BpsDenominator)),
	))
}

// proportionalMinimumOutput returns
// ceil(takingAmount * fillInput * (BpsDenominator-slippageBps) / (makingAmount * BpsDenominator)):
// the owner-net output a fill of fillInput must deliver, rounded up so the
// order's slippage-adjusted ratio is never undercut.
// Callers validate makingAmount > 0, takingAmount > 0, 0 <= fillInput <= makingAmount
// and 0 <= slippageBps <= BpsDenominator.
func proportionalMinimumOutput(makingAmount, takingAmount, slippageBps, fillInput int64) (int64, error) {
	numerator := u256.Zero().Mul(u256.NewUint(uint64(takingAmount)), u256.NewUint(uint64(fillInput)))
	numerator.Mul(numerator, u256.NewUint(uint64(BpsDenominator-slippageBps)))

	denominator := u256.Zero().Mul(u256.NewUint(uint64(makingAmount)), u256.NewUint(uint64(BpsDenominator)))

	return toInt64(u256.DivRoundingUp(numerator, denominator))
}

// requiredGrossOutput returns the least cumulative gross output whose
// owner-net share reaches requiredNet. With
// net(G) = G-floor(G*f/D) = ceil(G*(D-f)/D),
// it is floor((requiredNet-1)*D/(D-f))+1.
// requiredNet must be positive and executionFeeRate valid. The result may exceed
// MaxInt64, in which case it returns ErrAmountOverflow.
func requiredGrossOutput(requiredNet *u256.Uint, executionFeeRate int64) (int64, error) {
	numerator := u256.Zero().Sub(requiredNet, u256.One())
	required := u256.MulDiv(
		numerator,
		u256.NewUint(uint64(BpsDenominator)),
		u256.NewUint(uint64(BpsDenominator-executionFeeRate)),
	)
	required.Add(required, u256.One())

	return toInt64(required)
}

func isValidExecutionFeeRate(executionFeeRate int64) bool {
	return executionFeeRate >= 0 && executionFeeRate <= MaxExecutionFeeRate
}

// toInt64 converts a non-negative u256 to int64, or returns ErrAmountOverflow.
func toInt64(v *u256.Uint) (int64, error) {
	if v.Gt(maxInt64U256) {
		return 0, ErrAmountOverflow
	}

	return int64(v.Uint64()), nil
}
