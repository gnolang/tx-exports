package limit

import (
	"errors"
)

var (
	// ErrInvalidMakingAmount is returned when makingAmount is not positive.
	ErrInvalidMakingAmount = errors.New("invalid making amount (must be > 0)")

	// ErrInvalidTakingAmount is returned when takingAmount is not positive.
	ErrInvalidTakingAmount = errors.New("invalid taking amount (must be > 0)")

	// ErrInvalidSlippage is returned when slippageBps is outside [0, BpsDenominator].
	ErrInvalidSlippage = errors.New("invalid slippage")

	// ErrInvalidExpiresAt is returned when expiresAt is not positive.
	ErrInvalidExpiresAt = errors.New("invalid expiresAt (must be > 0)")

	// ErrOrderNotActive is returned when no input remains to fill.
	ErrOrderNotActive = errors.New("order is not active")

	// ErrOrderExpired is returned when filling an order at or after its deadline.
	ErrOrderExpired = errors.New("order has expired")

	// ErrInsufficientOutput is returned when a fill reports no output.
	ErrInsufficientOutput = errors.New("insufficient output amount")

	// ErrInvalidFillAmount is returned when a fill input is not in (0, remaining input].
	ErrInvalidFillAmount = errors.New("invalid fill amount")

	// ErrAmountOverflow is returned when an amount, including cumulative
	// gross output, would exceed MaxInt64.
	ErrAmountOverflow = errors.New("amount exceeds int64")

	// ErrSlippageExceeded is returned when a fill's owner-net output is below
	// the order's proportional minimum.
	ErrSlippageExceeded = errors.New("slippage exceeded, output less than minimum")

	// ErrInvalidExecutionFeeRate is returned when an execution fee rate is outside
	// [0, MaxExecutionFeeRate].
	ErrInvalidExecutionFeeRate = errors.New("invalid execution fee rate")
)
