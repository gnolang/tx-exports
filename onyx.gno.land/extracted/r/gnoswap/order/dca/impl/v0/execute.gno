package impl

import (
	"time"

	"gno.land/p/gnoswap/gnsmath/v1"
	pdca "gno.land/p/gnoswap/order/dca/v0"
	u256 "gno.land/p/gnoswap/uint256/v1"
	ufmt "gno.land/p/nt/ufmt/v0"

	"gno.land/r/gnoswap/access/v1"
	"gno.land/r/gnoswap/common"
	"gno.land/r/gnoswap/order/halt"
	"gno.land/r/gnoswap/order/whitelist"
)

// ExecuteGroup sells one round of a group with a pool swap
// and credits the swap output to the group accumulator.
// Each order's execution fee is deducted when the order is paid out;
// the round forwards the fee already pending for its output token.
// Only keepers allowed by gno.land/r/gnoswap/order/keeper may call it
// (DCAKeeperRole at deployment): the schedule and the swap result are checked on-chain,
// and a failed swap reverts so the round can be retried.
// minOrderAmountOut, raised to minOrderAmountOutFloor, is the least output
// every order of the round must be credited.
func (d *dcaOrderImpl) ExecuteGroup(
	_ int,
	rlm realm,
	groupID string,
	expectedAmountIn int64,
	amountOutMin int64,
	minOrderAmountOut int64,
) (int64, int64) {
	access.AssertIsRlmCurrent(0, rlm)
	common.AssertIsNotHandleNativeCoin()
	assertIsNotHalted(halt.OperationExecute, halt.OperationWithdraw)
	d.assertIsNotExecuting()

	if amountOutMin < 0 || expectedAmountIn < 0 || minOrderAmountOut < 0 {
		panic(makeErrorWithDetails(
			errInvalidAmount,
			ufmt.Sprintf(
				"expectedAmountIn(%d) amountOutMin(%d) minOrderAmountOut(%d)",
				expectedAmountIn, amountOutMin, minOrderAmountOut,
			),
		).Error())
	}

	if minOrderAmountOut < minOrderAmountOutFloor {
		minOrderAmountOut = minOrderAmountOutFloor
	}

	prev := rlm.Previous()
	assertIsAuthorizedKeeper(rlm.PkgPath(), prev.Address())

	group, err := d.getGroup(groupID)
	if err != nil {
		panic(err.Error())
	}

	currentTimestamp := time.Now().Unix()

	result, err := d.executeGroupRound(0, rlm, group, expectedAmountIn, amountOutMin, minOrderAmountOut, currentTimestamp)
	if err != nil {
		panic(err.Error())
	}

	emitGroupExecuted(prev.Address(), prev.PkgPath(), group, result)

	if result.forwardedExecutionFeeAmount > 0 || result.pendingExecutionFeeAmount > 0 {
		emitExecutionFeeCollected(
			prev.Address(),
			prev.PkgPath(),
			group.ID(),
			group.OutputToken(),
			group.Round(),
			0,
			result.forwardedExecutionFeeAmount,
			result.pendingExecutionFeeAmount,
		)
	}

	return result.executedAmountIn, result.executedAmountOut
}

// groupRoundResult describes one executed round.
type groupRoundResult struct {
	poolPath           string
	scheduledTimestamp int64
	executionTimestamp int64
	executedAmountIn   int64 // input sold, the group orderAmount
	swapAmountOut      int64 // pool output of the round
	executedAmountOut  int64 // output credited to the orders, before their execution fees
	endedOrderAmount   int64 // orderAmount of the orders whose last round this was

	forwardedExecutionFeeAmount int64 // pending execution fee sent to the protocol fee realm
	pendingExecutionFeeAmount   int64 // execution fee still held by this realm
}

// executeGroupRound runs the group's next round: it checks the schedule
// and the quoted input, picks the pool, swaps the whole round input within
// the pair price limit, and credits the pool output (swapAmountOut) to the
// accumulator per unit of the round input.
//
// The round charges no fee itself. Each order's execution fee is its own
// snapshotted executionFeeRate of its gross output, deducted when the order
// is paid out (Claim, ClaimGroupOrders, CancelOrder, ForceCancelOrder) and
// held as pending. The round forwards the fee pending for its output token to
// the protocol fee realm, so the fee still costs one transfer per round
// instead of one per order.
//
// Every order of the round must be credited at least minOrderAmountOut of
// output after its own execution fee rate. A round that cannot
// pay its smallest order that much is treated as lacking liquidity: it
// reverts, like a failed swap, so it can be retried.
//
// Checks-effects-interactions:
// the round, schedule, and next orderAmount are written before the pool
// swap, and an execution lock blocks re-entry while the swap and the
// pending execution fee transfer run.
// Only the swap-dependent accumulator is written after the swap.
func (d *dcaOrderImpl) executeGroupRound(
	_ int,
	rlm realm,
	group *pdca.Group,
	expectedAmountIn,
	amountOutMin,
	minOrderAmountOut,
	currentTimestamp int64,
) (groupRoundResult, error) {
	config := d.store.GetConfig()

	orderAmount := group.OrderAmount()
	if orderAmount <= 0 {
		return groupRoundResult{}, makeErrorWithDetails(errGroupNotExecutable, ufmt.Sprintf("groupId(%s) has no active order amount", group.ID()))
	}

	// Check the schedule first,
	// so a round already run by someone else reports "not executable".
	scheduledTimestamp := group.NextExecutionTimestamp()
	if currentTimestamp < scheduledTimestamp {
		return groupRoundResult{}, makeErrorWithDetails(
			errGroupNotExecutable,
			ufmt.Sprintf("groupId(%s) next execution at %d, now %d", group.ID(), scheduledTimestamp, currentTimestamp),
		)
	}

	// Orders may join or leave between the keeper's quote and inclusion;
	// the keeper then quotes again.
	assertIsQuotedAmountIn(group, expectedAmountIn, amountOutMin)

	// The pair price limit bounds the round's price and the pool's tick walk.
	priceLimit := getPairPriceLimit(d.store.GetPairPriceLimits(), group.InputToken(), group.OutputToken())

	selectedPool, err := selectRoundPool(whitelist.GetWhitelistedPools(whitelist.TargetDCA), priceLimit, config.MaxPoolPriceDeviationRate(), config.MaxPairPriceLimitAge(), group, orderAmount)
	if err != nil {
		return groupRoundResult{}, err
	}

	// Effects independent of the swap result.
	round := gnsmath.SafeAddUint64(group.Round(), 1)

	group.SetRound(round)

	// Orders ending at this round stop selling from the next round.
	roundMark := group.GetRoundMark(round)

	endedOrderAmount := int64(0)
	if roundMark != nil {
		endedOrderAmount = roundMark.OrderAmount()
	}

	// Move to the next slot without the ended order amount,
	// at least the execution gap after now.
	// A group with no order amount left drops out of the schedule index.
	minExecutionGap, err := pdca.CalculateMinExecutionGap(group.Interval(), config.MinExecutionGapRate())
	if err != nil {
		return groupRoundResult{}, err
	}

	nextExecutionTimestamp, err := pdca.CalculateNextExecutionTimestampWithGap(scheduledTimestamp, currentTimestamp, group.Interval(), minExecutionGap)
	if err != nil {
		return groupRoundResult{}, err
	}

	nextOrderAmount := gnsmath.SafeSubInt64(orderAmount, endedOrderAmount)
	if err := d.rescheduleGroup(group, nextOrderAmount, nextExecutionTimestamp); err != nil {
		return groupRoundResult{}, err
	}

	// Net payouts grow with amountPerExecution at one fee rate,
	// so the smallest order of each rate bounds every order's output.
	minAmounts := d.getFeeRateMinAmounts(group, round, true)
	if len(minAmounts) == 0 {
		return groupRoundResult{}, makeErrorWithDetails(
			errInvalidState,
			ufmt.Sprintf("groupId(%s) has no indexed order for round %d", group.ID(), round),
		)
	}

	if err := d.store.SetExecuting(0, rlm, true); err != nil {
		return groupRoundResult{}, err
	}

	swapAmountOut, err := swapExactIn(0, rlm, group, selectedPool.fee, selectedPool.sqrtPriceLimitX96, orderAmount, amountOutMin)
	if err != nil {
		return groupRoundResult{}, err
	}

	executedAmountOut := swapAmountOut

	outputPerAmountX128, err := pdca.CalculateOutputPerAmountX128(executedAmountOut, orderAmount)
	if err != nil {
		return groupRoundResult{}, err
	}

	if err := validateOrderOutput(group, minAmounts, minOrderAmountOut, outputPerAmountX128, executedAmountOut, orderAmount); err != nil {
		return groupRoundResult{}, err
	}

	accumulatedOutputPerAmountX128, overflow := u256.Zero().AddOverflow(group.AccumulatedOutputPerAmountX128(), outputPerAmountX128)
	if overflow {
		return groupRoundResult{}, makeErrorWithDetails(errOverflow, "accumulator overflow")
	}

	group.SetAccumulatedOutputPerAmountX128(accumulatedOutputPerAmountX128)

	if roundMark != nil {
		roundMark.SnapshotAccumulatedOutputPerAmountX128(accumulatedOutputPerAmountX128)
	}

	forwardedExecutionFeeAmount, pendingExecutionFeeAmount := d.collectExecutionFee(0, rlm, group.OutputToken(), 0)

	if err := d.store.SetExecuting(0, rlm, false); err != nil {
		return groupRoundResult{}, err
	}

	return groupRoundResult{
		poolPath:                    selectedPool.poolPath,
		scheduledTimestamp:          scheduledTimestamp,
		executionTimestamp:          currentTimestamp,
		executedAmountIn:            orderAmount,
		swapAmountOut:               swapAmountOut,
		executedAmountOut:           executedAmountOut,
		endedOrderAmount:            endedOrderAmount,
		forwardedExecutionFeeAmount: forwardedExecutionFeeAmount,
		pendingExecutionFeeAmount:   pendingExecutionFeeAmount,
	}, nil
}
