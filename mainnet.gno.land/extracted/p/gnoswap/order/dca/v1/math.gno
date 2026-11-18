package dca

import (
	"math"

	"gno.land/p/gnoswap/gnsmath/v1"
	u256 "gno.land/p/gnoswap/uint256/v1"
)

// Read-only constants: never pass them to a mutating u256 method.
var (
	q128         = u256.Zero().Lsh(u256.One(), 128)
	maxInt64U256 = u256.NewUintFromInt64(math.MaxInt64)
)

// Q128 returns a copy of 2^128, the accumulator scale.
func Q128() *u256.Uint {
	return q128.Clone()
}

// CalculateNextExecutionTimestamp returns the first slot strictly after
// currentTimestamp.
// Slots keep a fixed cadence from scheduledTimestamp,
// so a late execution skips missed slots instead of running them back to back.
// interval must be positive and the timestamps non-negative;
// a next slot above math.MaxInt64 returns ErrOverflow.
func CalculateNextExecutionTimestamp(scheduledTimestamp int64, currentTimestamp int64, interval int64) (int64, error) {
	if interval <= 0 || scheduledTimestamp < 0 || currentTimestamp < 0 {
		return 0, ErrInvalidInput
	}

	// Slots from scheduledTimestamp to the next one, at least one,
	// and the most that stay within math.MaxInt64.
	maxSlotCount := (math.MaxInt64 - scheduledTimestamp) / interval

	slotCount := int64(1)

	if currentTimestamp >= scheduledTimestamp {
		elapsedSlotCount := (currentTimestamp - scheduledTimestamp) / interval
		if elapsedSlotCount >= maxSlotCount {
			return 0, ErrOverflow
		}

		slotCount = gnsmath.SafeAddInt64(elapsedSlotCount, 1)
	}

	if slotCount > maxSlotCount {
		return 0, ErrOverflow
	}

	return gnsmath.SafeAddInt64(scheduledTimestamp, gnsmath.SafeMulInt64(slotCount, interval)), nil
}

// CalculateFirstSlotTimestamp returns the first slot at or after
// currentTimestamp, that is the smallest t >= currentTimestamp
// with t % interval == slotOffset.
// interval must be positive and slotOffset in [0, interval).
func CalculateFirstSlotTimestamp(currentTimestamp int64, interval int64, slotOffset int64) (int64, error) {
	if interval <= 0 || slotOffset < 0 || slotOffset >= interval || currentTimestamp < 0 {
		return 0, ErrInvalidInput
	}

	// slotOffset and the remainder are both in [0, interval),
	// so the wait stays within [0, interval) without overflowing.
	wait := slotOffset - currentTimestamp%interval
	if wait < 0 {
		wait = gnsmath.SafeAddInt64(wait, interval)
	}

	if currentTimestamp > math.MaxInt64-wait {
		return 0, ErrOverflow
	}

	return gnsmath.SafeAddInt64(currentTimestamp, wait), nil
}

// CalculateMinExecutionGap returns minExecutionGapRate (basis points) of
// interval in seconds, rounded up: the minimum time between two executions
// of a group.
func CalculateMinExecutionGap(interval int64, minExecutionGapRate int64) (int64, error) {
	if interval < 0 || minExecutionGapRate < 0 {
		return 0, ErrInvalidInput
	}

	return toInt64(u256.MulDivRoundingUp(
		u256.NewUint(uint64(interval)),
		u256.NewUint(uint64(minExecutionGapRate)),
		u256.NewUint(uint64(BasisPointDenominator)),
	))
}

// CalculateNextExecutionTimestampWithGap returns the first slot after
// currentTimestamp that is also at least minExecutionGap seconds after
// currentTimestamp.
// Like CalculateNextExecutionTimestamp, it keeps the cadence anchored at
// scheduledTimestamp, skipping slots that fall inside the gap.
// minExecutionGap must be non-negative; a gap reaching past math.MaxInt64
// returns ErrOverflow.
func CalculateNextExecutionTimestampWithGap(scheduledTimestamp int64, currentTimestamp int64, interval int64, minExecutionGap int64) (int64, error) {
	if minExecutionGap < 0 {
		return 0, ErrInvalidInput
	}

	// The next slot is strictly after its argument, so it is at least
	// minExecutionGap seconds after currentTimestamp.
	after := currentTimestamp
	if minExecutionGap > 0 {
		if currentTimestamp > math.MaxInt64-(minExecutionGap-1) {
			return 0, ErrOverflow
		}

		after += minExecutionGap - 1
	}

	return CalculateNextExecutionTimestamp(scheduledTimestamp, after, interval)
}

// CalculateExecutionFeeAmount returns
// amount * executionFeeRate / BasisPointDenominator,
// rounded down, so the fee never exceeds the configured share.
// Config.SetExecutionFeeRate bounds the rate to [0, MaxExecutionFeeRate].
func CalculateExecutionFeeAmount(amount int64, executionFeeRate int64) (int64, error) {
	if amount < 0 || executionFeeRate < 0 {
		return 0, ErrInvalidInput
	}

	return toInt64(calculateExecutionFeeAmountU256(u256.NewUint(uint64(amount)), executionFeeRate))
}

// CalculatePayoutExecutionFeeAmount returns the execution fee of a payout of
// grossAmount to an order already paid paidGrossAmount (its claimedAmount plus
// executionFeeAmount): fee(paidGrossAmount + grossAmount) - fee(paidGrossAmount),
// with fee as in CalculateExecutionFeeAmount.
//
// The fee is charged on the order's cumulative gross output, so splitting it
// over many payouts never rounds the fee away: after every payout the order's
// lifetime fee equals fee(its lifetime gross output).
// The result is at most ceil(grossAmount * executionFeeRate / BasisPointDenominator),
// so the payout net of the fee is at least
// CalculateMinNetAmountOut(grossAmount, executionFeeRate).
// It returns ErrInvalidInput for a negative grossAmount or a rate outside
// [0, MaxExecutionFeeRate].
func CalculatePayoutExecutionFeeAmount(paidGrossAmount *u256.Uint, grossAmount int64, executionFeeRate int64) (int64, error) {
	if grossAmount < 0 || !isValidExecutionFeeRate(executionFeeRate) {
		return 0, ErrInvalidInput
	}

	if grossAmount == 0 || executionFeeRate == 0 {
		return 0, nil
	}

	totalGrossAmount, overflow := u256.Zero().AddOverflow(paidGrossAmount, u256.NewUint(uint64(grossAmount)))
	if overflow {
		return 0, ErrOverflow
	}

	totalFeeAmount := calculateExecutionFeeAmountU256(totalGrossAmount, executionFeeRate)
	paidFeeAmount := calculateExecutionFeeAmountU256(paidGrossAmount, executionFeeRate)

	return toInt64(u256.Zero().Sub(totalFeeAmount, paidFeeAmount))
}

// CalculateMinNetAmountOut returns
// grossAmount * (BasisPointDenominator - executionFeeRate) / BasisPointDenominator,
// rounded down: the least an order paid grossAmount at executionFeeRate or
// less receives after CalculatePayoutExecutionFeeAmount, whatever it was paid
// before. A round checks its per-order output with it.
// It returns ErrInvalidInput for a negative grossAmount or a rate outside
// [0, MaxExecutionFeeRate].
func CalculateMinNetAmountOut(grossAmount int64, executionFeeRate int64) (int64, error) {
	if grossAmount < 0 || !isValidExecutionFeeRate(executionFeeRate) {
		return 0, ErrInvalidInput
	}

	return toInt64(u256.MulDiv(
		u256.NewUint(uint64(grossAmount)),
		u256.NewUint(uint64(BasisPointDenominator-executionFeeRate)),
		u256.NewUint(uint64(BasisPointDenominator)),
	))
}

// calculateExecutionFeeAmountU256 returns
// floor(amount * executionFeeRate / BasisPointDenominator).
// It is the single rounding rule of every execution fee.
func calculateExecutionFeeAmountU256(amount *u256.Uint, executionFeeRate int64) *u256.Uint {
	return u256.MulDiv(
		amount,
		u256.NewUint(uint64(executionFeeRate)),
		u256.NewUint(uint64(BasisPointDenominator)),
	)
}

// isValidExecutionFeeRate reports whether executionFeeRate is in
// [0, MaxExecutionFeeRate].
func isValidExecutionFeeRate(executionFeeRate int64) bool {
	return executionFeeRate >= 0 && executionFeeRate <= MaxExecutionFeeRate
}

// CalculateOutputPerAmountX128 returns amountOut * 2^128 / amountIn,
// rounded down: the output per unit of input of one round,
// added to the group accumulator.
func CalculateOutputPerAmountX128(amountOut int64, amountIn int64) (*u256.Uint, error) {
	if amountIn <= 0 || amountOut < 0 {
		return nil, ErrInvalidInput
	}

	return u256.MulDiv(u256.NewUint(uint64(amountOut)), q128, u256.NewUint(uint64(amountIn))), nil
}

// CalculateOwedAmount returns
// amountPerExecution * (endAccumulatedX128 - debtX128) / 2^128, rounded down:
// the output accrued since the last payout.
func CalculateOwedAmount(amountPerExecution int64, endAccumulatedX128 *u256.Uint, debtX128 *u256.Uint) (*u256.Uint, error) {
	if endAccumulatedX128.Lt(debtX128) {
		return nil, ErrAccumulatorBackwards
	}

	delta := u256.Zero().Sub(endAccumulatedX128, debtX128)
	if delta.IsZero() || amountPerExecution <= 0 {
		return u256.Zero(), nil
	}

	return u256.MulDiv(delta, u256.NewUint(uint64(amountPerExecution)), q128), nil
}

// CalculatePayout returns the output accrued since the last payout,
// amountPerExecution * (endAccumulatedX128 - debtX128) / 2^128 rounded down,
// paid in one transfer: a GRC20 total supply is at most math.MaxInt64, so
// the escrow, and any order's share of it, never exceeds one int64 transfer.
// After paying it the order's debt is endAccumulatedX128.
func CalculatePayout(amountPerExecution int64, endAccumulatedX128 *u256.Uint, debtX128 *u256.Uint) (int64, error) {
	owedAmount, err := CalculateOwedAmount(amountPerExecution, endAccumulatedX128, debtX128)
	if err != nil {
		return 0, err
	}

	return toInt64(owedAmount)
}

// CalculateDebtX128AfterPayout returns the debt of an order after it is
// paid payoutAmount: debtX128 + payoutAmount * 2^128 / amountPerExecution,
// rounded up.
// The debt moves only by the accumulator share that payoutAmount pays for,
// so the remainder CalculatePayout rounds down stays owed and is paid once
// it adds up to a whole unit.
// Rounding up never moves the debt past the end accumulator that paid out
// payoutAmount, so no payout is counted twice.
func CalculateDebtX128AfterPayout(amountPerExecution int64, debtX128 *u256.Uint, payoutAmount int64) (*u256.Uint, error) {
	if amountPerExecution <= 0 || payoutAmount < 0 {
		return nil, ErrInvalidInput
	}

	settledX128 := u256.MulDivRoundingUp(u256.NewUint(uint64(payoutAmount)), q128, u256.NewUint(uint64(amountPerExecution)))

	nextDebtX128, overflow := u256.Zero().AddOverflow(debtX128, settledX128)
	if overflow {
		return nil, ErrOverflow
	}

	return nextDebtX128, nil
}

// toInt64 converts a non-negative u256 to int64, or returns ErrOverflow.
func toInt64(v *u256.Uint) (int64, error) {
	if v.Gt(maxInt64U256) {
		return 0, ErrOverflow
	}

	return int64(v.Uint64()), nil
}
