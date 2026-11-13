package impl

import (
	"chain"

	plimit "gno.land/p/gnoswap/order/limit/v0"
	"gno.land/p/gnoswap/utils/v1"
)

func emitOrderCreated(prevAddr address, prevRealm string, order *plimit.Order, baseToken string) {
	chain.Emit(
		"LimitOrderCreated",
		"prevAddr", prevAddr.String(), "prevRealm", prevRealm,
		"owner", order.Owner().String(), "orderId", utils.FormatUint(order.ID()),
		"tokenIn", order.TokenIn(), "tokenOut", order.TokenOut(),
		"baseToken", baseToken,
		"makingAmount", utils.FormatInt(order.MakingAmount()), "takingAmount", utils.FormatInt(order.TakingAmount()),
		"slippageBps", utils.FormatInt(order.SlippageBps()),
		"createdAt", utils.FormatInt(order.CreatedAt()), "expiresAt", utils.FormatInt(order.ExpiresAt()),
		"executionFeeRate", utils.FormatInt(order.ExecutionFeeRate()),
	)
}

func emitOrderFilled(prevAddr address, prevRealm string, order *plimit.Order, route string, amountIn, poolOutput, executionFee int64) {
	chain.Emit(
		"LimitOrderFilled",
		"prevAddr", prevAddr.String(), "prevRealm", prevRealm,
		"owner", order.Owner().String(), "orderId", utils.FormatUint(order.ID()),
		"route", route,
		"tokenIn", order.TokenIn(), "tokenOut", order.TokenOut(),
		"amountIn", utils.FormatInt(amountIn), "poolOutput", utils.FormatInt(poolOutput),
		"userOutput", utils.FormatInt(poolOutput-executionFee), "executionFee", utils.FormatInt(executionFee),
		"filledInput", utils.FormatInt(order.FilledInput()), "remainingInput", utils.FormatInt(order.RemainingInput()),
		"refundedInput", utils.FormatInt(order.RefundedInput()),
		"grossOutput", utils.FormatInt(order.GrossOutput()), "cumulativeExecutionFee", utils.FormatInt(order.ExecutionFee()),
	)
}

func emitExecutionFeeCollected(
	prevAddr address,
	prevRealm string,
	orderID uint64,
	tokenPath string,
	executionFeeAmount int64,
	forwardedAmount int64,
	pendingAmount int64,
) {
	chain.Emit(
		"LimitExecutionFeeCollected",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"orderId", utils.FormatUint(orderID),
		"tokenPath", tokenPath,
		"executionFeeAmount", utils.FormatInt(executionFeeAmount),
		"forwardedAmount", utils.FormatInt(forwardedAmount),
		"pendingAmount", utils.FormatInt(pendingAmount),
	)
}

func emitOrderCompleted(prevAddr address, prevRealm string, order *plimit.Order) {
	chain.Emit(
		"LimitOrderCompleted",
		"prevAddr", prevAddr.String(), "prevRealm", prevRealm,
		"owner", order.Owner().String(), "orderId", utils.FormatUint(order.ID()),
		"filledInput", utils.FormatInt(order.FilledInput()), "refundedInput", utils.FormatInt(order.RefundedInput()),
		"grossOutput", utils.FormatInt(order.GrossOutput()), "cumulativeExecutionFee", utils.FormatInt(order.ExecutionFee()),
		"userOutput", utils.FormatInt(order.GrossOutput()-order.ExecutionFee()),
	)
}

func emitOrderRefunded(prevAddr address, prevRealm string, order *plimit.Order, refund int64, expired bool) {
	name := "LimitOrderCancelled"
	if expired {
		name = "LimitOrderExpired"
	}

	emitOrderInputRefunded(name, prevAddr, prevRealm, order, refund)
}

func emitOrderInputRefunded(name string, prevAddr address, prevRealm string, order *plimit.Order, refund int64) {
	chain.Emit(
		name,
		"prevAddr", prevAddr.String(), "prevRealm", prevRealm,
		"owner", order.Owner().String(), "orderId", utils.FormatUint(order.ID()),
		"tokenIn", order.TokenIn(), "tokenOut", order.TokenOut(),
		"refundIn", utils.FormatInt(refund), "refundedInput", utils.FormatInt(order.RefundedInput()),
		"filledInput", utils.FormatInt(order.FilledInput()), "remainingInput", utils.FormatInt(order.RemainingInput()),
		"grossOutput", utils.FormatInt(order.GrossOutput()), "cumulativeExecutionFee", utils.FormatInt(order.ExecutionFee()),
		"userOutput", utils.FormatInt(order.GrossOutput()-order.ExecutionFee()),
	)
}

func emitOrderCleanupInsufficientBalance(prevAddr address, prevRealm string, order *plimit.Order, refund, balance int64) {
	chain.Emit(
		"LimitOrderCleanupInsufficientBalance",
		"prevAddr", prevAddr.String(), "prevRealm", prevRealm,
		"owner", order.Owner().String(), "orderId", utils.FormatUint(order.ID()),
		"tokenIn", order.TokenIn(),
		"refundAmount", utils.FormatInt(refund), "balance", utils.FormatInt(balance),
	)
}

func emitConfigUpdated(prevAddr address, prevRealm, key, previous, next string) {
	chain.Emit(
		"LimitOrderConfigUpdated",
		"prevAddr", prevAddr.String(), "prevRealm", prevRealm,
		"key", key, "prevValue", previous, "newValue", next,
	)
}

func emitExecutionFeeRateChanged(prevAddr address, prevRealm string, previousExecutionFeeRate int64, executionFeeRate int64) {
	chain.Emit(
		"LimitExecutionFeeRateChanged",
		"prevAddr", prevAddr.String(),
		"prevRealm", prevRealm,
		"previousExecutionFeeRate", utils.FormatInt(previousExecutionFeeRate),
		"executionFeeRate", utils.FormatInt(executionFeeRate),
	)
}
