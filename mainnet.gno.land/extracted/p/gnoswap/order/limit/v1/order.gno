package limit

import (
	"math"

	u256 "gno.land/p/gnoswap/uint256/v1"
)

// OrderStatus is the time-derived lifecycle state of a pending limit order.
type OrderStatus string

const (
	// OrderStatusOpen: no input has been filled and the order has not expired.
	OrderStatusOpen OrderStatus = "OPEN"
	// OrderStatusPartiallyFilled: some input has been filled while unexpired.
	OrderStatusPartiallyFilled OrderStatus = "PARTIALLY_FILLED"
	// OrderStatusExpired: the deadline has been reached while input awaits refund.
	OrderStatusExpired OrderStatus = "EXPIRED"
)

func (s OrderStatus) String() string {
	return string(s)
}

// Order keeps the original net exchange ratio and execution fee rate
// snapshotted at creation. grossOutput is the output received from the pool.
// Execution fees are paid at each fill, but rounded on cumulative gross output
// so splitting cannot evade them. Every amount, including cumulative gross
// output, stays within MaxInt64.
type Order struct {
	id       uint64
	owner    address
	tokenIn  string
	tokenOut string

	makingAmount     int64
	takingAmount     int64
	slippageBps      int64
	executionFeeRate int64

	createdAt int64
	expiresAt int64

	filledInput   int64
	refundedInput int64
	grossOutput   int64
	executionFee  int64
}

// NewOrder creates an order with executionFeeRate snapshotted for its lifetime.
// Domain terms, including a positive expiry, are validated here;
// token registration and configured duration bounds belong to the implementation.
func NewOrder(
	id uint64,
	owner address,
	tokenIn string,
	tokenOut string,
	makingAmount int64,
	takingAmount int64,
	slippageBps int64,
	executionFeeRate int64,
	createdAt int64,
	expiresAt int64,
) (*Order, error) {
	if makingAmount <= 0 {
		return nil, ErrInvalidMakingAmount
	}

	if takingAmount <= 0 {
		return nil, ErrInvalidTakingAmount
	}

	if slippageBps < 0 || slippageBps > BpsDenominator {
		return nil, ErrInvalidSlippage
	}

	if !isValidExecutionFeeRate(executionFeeRate) {
		return nil, ErrInvalidExecutionFeeRate
	}

	if expiresAt <= 0 {
		return nil, ErrInvalidExpiresAt
	}

	return &Order{
		id:               id,
		owner:            owner,
		tokenIn:          tokenIn,
		tokenOut:         tokenOut,
		makingAmount:     makingAmount,
		takingAmount:     takingAmount,
		slippageBps:      slippageBps,
		executionFeeRate: executionFeeRate,
		createdAt:        createdAt,
		expiresAt:        expiresAt,
	}, nil
}

func (o *Order) ID() uint64              { return o.id }
func (o *Order) Owner() address          { return o.owner }
func (o *Order) TokenIn() string         { return o.tokenIn }
func (o *Order) TokenOut() string        { return o.tokenOut }
func (o *Order) MakingAmount() int64     { return o.makingAmount }
func (o *Order) TakingAmount() int64     { return o.takingAmount }
func (o *Order) SlippageBps() int64      { return o.slippageBps }
func (o *Order) ExecutionFeeRate() int64 { return o.executionFeeRate }

// Status derives the order lifecycle state at the supplied Unix timestamp.
func (o *Order) Status(now int64) OrderStatus {
	if o.IsExpired(now) {
		return OrderStatusExpired
	}

	if o.FilledInput() > 0 {
		return OrderStatusPartiallyFilled
	}

	return OrderStatusOpen
}
func (o *Order) CreatedAt() int64     { return o.createdAt }
func (o *Order) ExpiresAt() int64     { return o.expiresAt }
func (o *Order) FilledInput() int64   { return o.filledInput }
func (o *Order) RefundedInput() int64 { return o.refundedInput }
func (o *Order) GrossOutput() int64   { return o.grossOutput }
func (o *Order) ExecutionFee() int64  { return o.executionFee }

// Clone returns a detached copy that shares no mutable state with o.
// Fields are copied one by one, so a field added later must be added here.
func (o *Order) Clone() *Order {
	return &Order{
		id:       o.id,
		owner:    o.owner,
		tokenIn:  o.tokenIn,
		tokenOut: o.tokenOut,

		makingAmount:     o.makingAmount,
		takingAmount:     o.takingAmount,
		slippageBps:      o.slippageBps,
		executionFeeRate: o.executionFeeRate,

		createdAt: o.createdAt,
		expiresAt: o.expiresAt,

		filledInput:   o.filledInput,
		refundedInput: o.refundedInput,
		grossOutput:   o.grossOutput,
		executionFee:  o.executionFee,
	}
}

// RemainingInput returns escrowed input not yet filled or refunded.
func (o *Order) RemainingInput() int64 {
	return o.makingAmount - o.filledInput - o.refundedInput
}

// IsExpired reports whether the deadline has been reached at now.
func (o *Order) IsExpired(now int64) bool {
	return now >= o.expiresAt
}

// IsActive reports whether unfilled input can accept a fill at now.
func (o *Order) IsActive(now int64) bool {
	return !o.IsExpired(now) && o.RemainingInput() > 0
}

// MinimumUserOutput returns the owner-net output a fill of fillInput must
// deliver: the slippage-adjusted original ratio, rounded up.
func (o *Order) MinimumUserOutput(fillInput int64) (int64, error) {
	if fillInput <= 0 || fillInput > o.RemainingInput() {
		return 0, ErrInvalidFillAmount
	}

	return proportionalMinimumOutput(o.makingAmount, o.takingAmount, o.slippageBps, fillInput)
}

// GetMinimumOutput returns the exact minimum pool output needed by a
// fillInput, including the next cumulative execution-fee rounding
// boundary. It returns ErrAmountOverflow when no fill could satisfy the
// minimum without cumulative gross output exceeding MaxInt64.
func (o *Order) GetMinimumOutput(fillInput int64) (int64, error) {
	minimum, err := o.MinimumUserOutput(fillInput)
	if err != nil {
		return 0, err
	}

	// A zero owner minimum still requires a positive pool output.
	if minimum == 0 {
		if o.grossOutput == math.MaxInt64 {
			return 0, ErrAmountOverflow
		}

		return 1, nil
	}

	requiredNet := u256.NewUint(uint64(o.grossOutput - o.executionFee))
	requiredNet.Add(requiredNet, u256.NewUint(uint64(minimum)))

	requiredGross, err := requiredGrossOutput(requiredNet, o.executionFeeRate)
	if err != nil {
		return 0, err
	}

	return requiredGross - o.grossOutput, nil
}

// ApplyFill records a fill of fillInput that produced poolOutput at now.
// It validates every quantity before changing any accounting; on error the
// order is unchanged.
func (o *Order) ApplyFill(fillInput, poolOutput, now int64) error {
	if o.RemainingInput() <= 0 {
		return ErrOrderNotActive
	}

	if o.IsExpired(now) {
		return ErrOrderExpired
	}

	minimum, err := o.MinimumUserOutput(fillInput)
	if err != nil {
		return err
	}

	if poolOutput <= 0 {
		return ErrInsufficientOutput
	}

	if poolOutput > math.MaxInt64-o.grossOutput {
		return ErrAmountOverflow
	}

	gross := o.grossOutput + poolOutput

	executionFee, err := CumulativeExecutionFee(gross, o.executionFeeRate)
	if err != nil {
		return err
	}

	if poolOutput-(executionFee-o.executionFee) < minimum {
		return ErrSlippageExceeded
	}

	o.filledInput += fillInput
	o.grossOutput = gross
	o.executionFee = executionFee

	return nil
}

// RefundInput consumes the remaining escrow exactly once and returns it,
// without pretending that refunded input was traded. Later calls return 0.
func (o *Order) RefundInput() int64 {
	remaining := o.RemainingInput()
	o.refundedInput += remaining

	return remaining
}
