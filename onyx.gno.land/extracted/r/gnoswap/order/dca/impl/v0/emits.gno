package impl

import (
	"chain"

	pdca "gno.land/p/gnoswap/order/dca/v0"
	"gno.land/p/gnoswap/utils/v1"
)

// Events carry the accumulator state
// (accumulatedOutputPerAmountX128, round, orderAmount) and each order's
// payout state, so indexers can compute claimable amounts without querying
// state. The accumulator is gross of execution fees:
//
//	gross = amountPerExecution * (acc(min(round, endRound)) - debtX128) / 2^128
//	paid  = totalClaimedAmount + totalExecutionFeeAmount
//	fee   = floor((paid + gross) * executionFeeRate / 10000) - floor(paid * executionFeeRate / 10000)
//	claimable = gross - fee

func emitGroupCreated(prevAddr address, prevRealm string, group *pdca.Group) {
	chain.Emit(
		"DCAGroupCreated",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"groupId", group.ID(),
		"inputToken", group.InputToken(),
		"outputToken", group.OutputToken(),
		"interval", utils.FormatInt(group.Interval()),
		"slotOffset", utils.FormatInt(group.SlotOffset()),
		"nextExecutionTimestamp", utils.FormatInt(group.NextExecutionTimestamp()),
	)
}

// emitOrderCreated reports a new order. executionFeeRate is the rate the
// order snapshotted. referenceAmountOut is the output of selling the whole
// deposit at once when the order was placed, net of the order's execution
// fee (see quoteReferenceAmountOut), 0 when no pool could absorb it.
func emitOrderCreated(
	prevAddr address,
	prevRealm string,
	order *pdca.Order,
	group *pdca.Group,
	depositAmount int64,
	referenceAmountOut int64,
) {
	chain.Emit(
		"DCAOrderCreated",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"orderId", utils.FormatUint(order.ID()),
		"owner", order.Owner().String(),
		"groupId", order.GroupID(),
		"inputToken", group.InputToken(),
		"outputToken", group.OutputToken(),
		"interval", utils.FormatInt(group.Interval()),
		"slotOffset", utils.FormatInt(group.SlotOffset()),
		"amountPerExecution", utils.FormatInt(order.AmountPerExecution()),
		"executionCount", utils.FormatInt(order.ExecutionCount()),
		"executionFeeRate", utils.FormatInt(order.ExecutionFeeRate()),
		"depositAmount", utils.FormatInt(depositAmount),
		"startRound", utils.FormatUint(order.StartRound()),
		"endRound", utils.FormatUint(order.EndRound()),
		"debtX128", order.DebtX128().ToString(),
		"executionLogCount", utils.FormatInt(order.ExecutionLogCount()),
		"groupOrderAmount", utils.FormatInt(group.OrderAmount()),
		"groupNextExecutionTimestamp", utils.FormatInt(group.NextExecutionTimestamp()),
		"referenceAmountOut", utils.FormatInt(referenceAmountOut),
	)
}

// emitGroupExecuted reports a round. executedAmountOut, the output credited
// to the orders, equals swapAmountOut: orders pay their execution fees when
// paid out.
func emitGroupExecuted(prevAddr address, prevRealm string, group *pdca.Group, result groupRoundResult) {
	chain.Emit(
		"DCAGroupExecuted",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"groupId", group.ID(),
		"poolPath", result.poolPath,
		"inputToken", group.InputToken(),
		"outputToken", group.OutputToken(),
		"round", utils.FormatUint(group.Round()),
		"executedAmountIn", utils.FormatInt(result.executedAmountIn),
		"swapAmountOut", utils.FormatInt(result.swapAmountOut),
		"executedAmountOut", utils.FormatInt(result.executedAmountOut),
		"accumulatedOutputPerAmountX128", group.AccumulatedOutputPerAmountX128().ToString(),
		"endedOrderAmount", utils.FormatInt(result.endedOrderAmount),
		"nextOrderAmount", utils.FormatInt(group.OrderAmount()),
		"scheduledTimestamp", utils.FormatInt(result.scheduledTimestamp),
		"executionTimestamp", utils.FormatInt(result.executionTimestamp),
		"nextExecutionTimestamp", utils.FormatInt(group.NextExecutionTimestamp()),
	)
}

func emitGroupOrdersClaimed(
	prevAddr address,
	prevRealm string,
	groupID string,
	examinedOrderCount int,
	claimedOrderCount int,
	releasedExecutionLogCount int64,
	nextCursor uint64,
) {
	chain.Emit(
		"DCAGroupOrdersClaimed",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"groupId", groupID,
		"examinedOrderCount", utils.FormatInt(int64(examinedOrderCount)),
		"claimedOrderCount", utils.FormatInt(int64(claimedOrderCount)),
		"releasedExecutionLogCount", utils.FormatInt(releasedExecutionLogCount),
		"nextCursor", utils.FormatUint(nextCursor),
	)
}

// emitOrderClaimed reports a payout. grossAmount is the accrued output paid
// out, executionFeeAmount the order's fee on it, and claimedAmount the rest,
// sent to the owner; the totals are the order's lifetime values.
func emitOrderClaimed(
	prevAddr address,
	prevRealm string,
	order *pdca.Order,
	group *pdca.Group,
	payout orderPayout,
	status pdca.OrderStatus,
) {
	chain.Emit(
		"DCAOrderClaimed",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"orderId", utils.FormatUint(order.ID()),
		"owner", order.Owner().String(),
		"groupId", order.GroupID(),
		"outputToken", group.OutputToken(),
		"grossAmount", utils.FormatInt(payout.grossAmount),
		"executionFeeRate", utils.FormatInt(order.ExecutionFeeRate()),
		"executionFeeAmount", utils.FormatInt(payout.executionFeeAmount),
		"claimedAmount", utils.FormatInt(payout.claimedAmount),
		"totalClaimedAmount", order.ClaimedAmount().ToString(),
		"totalExecutionFeeAmount", order.ExecutionFeeAmount().ToString(),
		"debtX128", order.DebtX128().ToString(),
		"status", status.String(),
	)
}

func emitOrderCancelled(
	prevAddr address,
	prevRealm string,
	order *pdca.Order,
	group *pdca.Group,
	payout orderPayout,
	refundedAmount int64,
) {
	chain.Emit(
		"DCAOrderCancelled",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"orderId", utils.FormatUint(order.ID()),
		"owner", order.Owner().String(),
		"groupId", order.GroupID(),
		"inputToken", group.InputToken(),
		"outputToken", group.OutputToken(),
		"refundedAmount", utils.FormatInt(refundedAmount),
		"grossAmount", utils.FormatInt(payout.grossAmount),
		"executionFeeRate", utils.FormatInt(order.ExecutionFeeRate()),
		"executionFeeAmount", utils.FormatInt(payout.executionFeeAmount),
		"claimedAmount", utils.FormatInt(payout.claimedAmount),
		"totalClaimedAmount", order.ClaimedAmount().ToString(),
		"totalExecutionFeeAmount", order.ExecutionFeeAmount().ToString(),
		"debtX128", order.DebtX128().ToString(),
		"status", pdca.OrderStatusCancelled.String(),
		"cancelRound", utils.FormatUint(group.Round()),
		"groupOrderAmount", utils.FormatInt(group.OrderAmount()),
	)
}

// emitPayoutExecutionFee reports the execution fee a payout of the group's
// orders charged and kept as pending, if any.
func emitPayoutExecutionFee(prevAddr address, prevRealm string, group *pdca.Group, executionFeeAmount int64, pendingAmount int64) {
	if executionFeeAmount <= 0 {
		return
	}

	emitExecutionFeeCollected(prevAddr, prevRealm, group.ID(), group.OutputToken(), group.Round(), executionFeeAmount, 0, pendingAmount)
}

// emitExecutionFeeCollected reports execution fees of tokenPath.
// executionFeeAmount is the fee payouts charged (0 for a round or
// CollectPendingExecutionFee), forwardedAmount what was sent to the protocol
// fee realm, and pendingAmount what this realm still holds.
// groupId is empty and round 0 for CollectPendingExecutionFee.
func emitExecutionFeeCollected(
	prevAddr address,
	prevRealm string,
	groupID string,
	tokenPath string,
	round uint64,
	executionFeeAmount int64,
	forwardedAmount int64,
	pendingAmount int64,
) {
	chain.Emit(
		"DCAExecutionFeeCollected",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"groupId", groupID,
		"tokenPath", tokenPath,
		"round", utils.FormatUint(round),
		"executionFeeAmount", utils.FormatInt(executionFeeAmount),
		"forwardedAmount", utils.FormatInt(forwardedAmount),
		"pendingAmount", utils.FormatInt(pendingAmount),
	)
}

func emitExecutionFeeRateChanged(prevAddr address, prevRealm string, previousExecutionFeeRate int64, executionFeeRate int64) {
	chain.Emit(
		"DCAExecutionFeeRateChanged",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"previousExecutionFeeRate", utils.FormatInt(previousExecutionFeeRate),
		"executionFeeRate", utils.FormatInt(executionFeeRate),
	)
}

func emitSlotStepChanged(prevAddr address, prevRealm string, interval int64, previousSlotStep int64, slotStep int64) {
	chain.Emit(
		"DCASlotStepChanged",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"interval", utils.FormatInt(interval),
		"previousSlotStep", utils.FormatInt(previousSlotStep),
		"slotStep", utils.FormatInt(slotStep),
	)
}

func emitExecutionLogsReleased(prevAddr address, prevRealm string, order *pdca.Order, group *pdca.Group, releasedExecutionLogCount int64) {
	chain.Emit(
		"DCAExecutionLogsReleased",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"orderId", utils.FormatUint(order.ID()),
		"groupId", group.ID(),
		"round", utils.FormatUint(group.Round()),
		"releasedExecutionLogCount", utils.FormatInt(releasedExecutionLogCount),
		"remainingExecutionLogCount", utils.FormatInt(order.ExecutionLogCount()),
	)
}

func emitConfigUpdated(prevAddr address, prevRealm string, key string, previousValue int64, value int64) {
	chain.Emit(
		"DCAConfigUpdated",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"key", key,
		"previousValue", utils.FormatInt(previousValue),
		"value", utils.FormatInt(value),
	)
}

func emitAllowedIntervalUpdated(prevAddr address, prevRealm string, interval int64, allowed bool) {
	chain.Emit(
		"DCAAllowedIntervalUpdated",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"interval", utils.FormatInt(interval),
		"allowed", utils.FormatBool(allowed),
	)
}

// emitOrderForceCancelled reports an order closed by a keeper with ForceCancelOrder.
// It carries the fields of DCAOrderCancelled and the reason the order blocked
// its group (see ForceCancelOrder); the order's status is
// cancelled, and its output and refund went to the owner.
func emitOrderForceCancelled(
	prevAddr address,
	prevRealm string,
	order *pdca.Order,
	group *pdca.Group,
	payout orderPayout,
	refundedAmount int64,
	reason string,
) {
	chain.Emit(
		"DCAOrderForceCancelled",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"orderId", utils.FormatUint(order.ID()),
		"owner", order.Owner().String(),
		"groupId", order.GroupID(),
		"inputToken", group.InputToken(),
		"outputToken", group.OutputToken(),
		"refundedAmount", utils.FormatInt(refundedAmount),
		"grossAmount", utils.FormatInt(payout.grossAmount),
		"executionFeeRate", utils.FormatInt(order.ExecutionFeeRate()),
		"executionFeeAmount", utils.FormatInt(payout.executionFeeAmount),
		"claimedAmount", utils.FormatInt(payout.claimedAmount),
		"totalClaimedAmount", order.ClaimedAmount().ToString(),
		"totalExecutionFeeAmount", order.ExecutionFeeAmount().ToString(),
		"debtX128", order.DebtX128().ToString(),
		"status", pdca.OrderStatusCancelled.String(),
		"cancelRound", utils.FormatUint(group.Round()),
		"groupOrderAmount", utils.FormatInt(group.OrderAmount()),
		"reason", reason,
	)
}

func emitTokenMinAmountPerExecutionUpdated(
	prevAddr address,
	prevRealm string,
	tokenPath string,
	previousMinAmountPerExecution int64,
	minAmountPerExecution int64,
) {
	chain.Emit(
		"DCATokenMinAmountPerExecutionUpdated",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"tokenPath", tokenPath,
		"prevMinAmountPerExecution", utils.FormatInt(previousMinAmountPerExecution),
		"minAmountPerExecution", utils.FormatInt(minAmountPerExecution),
	)
}

// emitPairPriceLimitUpdated reports a pair price limit change;
// minOutputPerInputX128 "0" and updatedAt 0 mean the limit was removed.
func emitPairPriceLimitUpdated(
	prevAddr address,
	prevRealm string,
	inputToken string,
	outputToken string,
	previousMinOutputPerInputX128 string,
	minOutputPerInputX128 string,
	updatedAt int64,
) {
	chain.Emit(
		"DCAPairPriceLimitUpdated",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"inputToken", inputToken,
		"outputToken", outputToken,
		"prevMinOutputPerInputX128", previousMinOutputPerInputX128,
		"minOutputPerInputX128", minOutputPerInputX128,
		"updatedAt", utils.FormatInt(updatedAt),
	)
}
