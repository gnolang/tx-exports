package dca

import (
	"gno.land/p/gnoswap/gnsmath/v1"
	"math"

	u256 "gno.land/p/gnoswap/uint256/v1"
)

// OrderStatus is the outcome reported in order events.
// Stored orders are always active: a completed or cancelled order is
// deleted, and its final state is kept in the event.
type OrderStatus string

const (
	// OrderStatusActive: still selling input or holding unclaimed output.
	OrderStatusActive OrderStatus = "ACTIVE"
	// OrderStatusCompleted: every round executed and all output was paid.
	OrderStatusCompleted OrderStatus = "COMPLETED"
	// OrderStatusCancelled: cancelled by the owner; unsold input was refunded.
	OrderStatusCancelled OrderStatus = "CANCELLED"
)

func (s OrderStatus) String() string {
	return string(s)
}

// Order u256 setters copy the value into the field's existing object
// instead of attaching a new one: updates create no objects, and an order
// can be deleted in the same transaction it was updated in.
// Getters return copies, so stored values are never shared.

// Order is one user's active DCA order.
// It sells amountPerExecution of the group's input token
// in each group round of (startRound, endRound].
// Accrued gross output is
// amountPerExecution * (acc(min(round, endRound)) - debtX128) / 2^128;
// each payout deducts the order's execution fee from it
// (see CalculatePayoutExecutionFeeAmount).
// The execution fee rate is snapshotted at creation for the order's lifetime.
// Only the payout state (debtX128, claimedAmount, executionFeeAmount) and the
// released execution logs change after creation.
type Order struct {
	id    uint64
	owner address

	groupID string // tokens and interval are on the group

	amountPerExecution int64
	startRound         uint64
	endRound           uint64

	// executionFeeRate is the share of the order's gross output,
	// in basis points, charged when it is paid out.
	executionFeeRate int64

	debtX128      *u256.Uint // group accumulator already paid out, see CalculateDebtX128AfterPayout
	claimedAmount *u256.Uint // lifetime output paid to the owner, net of the execution fee; 256-bit so it never overflows

	// executionFeeAmount is the lifetime execution fee charged on payouts;
	// claimedAmount + executionFeeAmount is the gross output paid out.
	executionFeeAmount *u256.Uint

	// Last round whose execution log was released;
	// the logs of rounds (releasedRound, endRound] are stored.
	releasedRound uint64

	createdTimestamp int64
	createdHeight    int64
}

// NewOrder creates an order that joins group at its current round.
// Store its execution logs with AllocateExecutionLogs.
// Its debt starts at the group's current accumulated output per amount,
// so it never shares output from earlier rounds.
// executionFeeRate is fixed for the order's lifetime.
// It returns ErrInvalidInput if executionCount is not positive or
// executionFeeRate is outside [0, MaxExecutionFeeRate],
// and ErrOverflow if the end round would pass the uint64 limit.
func NewOrder(
	id uint64,
	owner address,
	group *Group,
	amountPerExecution int64,
	executionCount int64,
	executionFeeRate int64,
	createdTimestamp int64,
	createdHeight int64,
) (*Order, error) {
	if executionCount <= 0 || !isValidExecutionFeeRate(executionFeeRate) {
		return nil, ErrInvalidInput
	}

	startRound := group.Round()
	if uint64(executionCount) > math.MaxUint64-startRound {
		return nil, ErrOverflow
	}

	return &Order{
		id:                 id,
		owner:              owner,
		groupID:            group.ID(),
		amountPerExecution: amountPerExecution,
		startRound:         startRound,
		endRound:           gnsmath.SafeAddUint64(startRound, uint64(executionCount)),
		executionFeeRate:   executionFeeRate,
		debtX128:           group.AccumulatedOutputPerAmountX128(), // already a copy
		claimedAmount:      u256.Zero(),
		executionFeeAmount: u256.Zero(),
		releasedRound:      startRound,
		createdTimestamp:   createdTimestamp,
		createdHeight:      createdHeight,
	}, nil
}

// Clone returns a deep copy of the order,
// so callers can read it without aliasing stored state.
func (o *Order) Clone() *Order {
	return &Order{
		id:                 o.id,
		owner:              o.owner,
		groupID:            o.groupID,
		amountPerExecution: o.amountPerExecution,
		startRound:         o.startRound,
		endRound:           o.endRound,
		executionFeeRate:   o.executionFeeRate,
		debtX128:           o.debtX128.Clone(),
		claimedAmount:      o.claimedAmount.Clone(),
		executionFeeAmount: o.executionFeeAmount.Clone(),
		releasedRound:      o.releasedRound,
		createdTimestamp:   o.createdTimestamp,
		createdHeight:      o.createdHeight,
	}
}

func (o *Order) ID() uint64                { return o.id }
func (o *Order) Owner() address            { return o.owner }
func (o *Order) GroupID() string           { return o.groupID }
func (o *Order) AmountPerExecution() int64 { return o.amountPerExecution }
func (o *Order) ExecutionCount() int64     { return int64(o.endRound - o.startRound) }
func (o *Order) StartRound() uint64        { return o.startRound }
func (o *Order) EndRound() uint64          { return o.endRound }
func (o *Order) ExecutionFeeRate() int64   { return o.executionFeeRate }
func (o *Order) CreatedTimestamp() int64   { return o.createdTimestamp }
func (o *Order) CreatedHeight() int64      { return o.createdHeight }

func (o *Order) DebtX128() *u256.Uint     { return o.debtX128.Clone() }
func (o *Order) SetDebtX128(v *u256.Uint) { o.debtX128.Set(v) }

func (o *Order) ClaimedAmount() *u256.Uint     { return o.claimedAmount.Clone() }
func (o *Order) SetClaimedAmount(v *u256.Uint) { o.claimedAmount.Set(v) }

func (o *Order) ExecutionFeeAmount() *u256.Uint     { return o.executionFeeAmount.Clone() }
func (o *Order) SetExecutionFeeAmount(v *u256.Uint) { o.executionFeeAmount.Set(v) }

// PaidGrossAmount returns the gross output paid out so far:
// claimedAmount plus executionFeeAmount.
func (o *Order) PaidGrossAmount() *u256.Uint {
	return u256.Zero().Add(o.claimedAmount, o.executionFeeAmount)
}

// ExecutionLogCount returns the number of the order's unreleased logs.
// Logs start at fixed offsets from the start round, so no lookup is needed.
func (o *Order) ExecutionLogCount() int64 {
	remainingRoundCount := o.endRound - o.releasedRound

	logCount := remainingRoundCount / ExecutionLogRoundCount
	if remainingRoundCount%ExecutionLogRoundCount != 0 {
		logCount = gnsmath.SafeAddUint64(logCount, 1)
	}

	return gnsmath.SafeUint64ToInt64(logCount)
}

// setReleasedRound is a method, not a field write, so an implementation
// other than the order's creator can update it after an upgrade.
func (o *Order) setReleasedRound(round uint64) { o.releasedRound = round }
