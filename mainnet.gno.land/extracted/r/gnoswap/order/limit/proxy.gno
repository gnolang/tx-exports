package limit

type expiredOrderCleanup interface {
	CleanupExpiredOrdersByIDs(_ int, rlm realm, orderIDs string) (expired int, retryOrderIDs string)
}

type pendingExecutionFeeCollector interface {
	CollectPendingExecutionFee(_ int, rlm realm, tokenPath string) (int64, int64)
}

// CreateOrder escrows makingAmount of tokenIn for takingAmount of tokenOut.
// Each fill supplies its pool fee tier and price limit.
// slippageBps=0 enforces the making/taking ratio or better.
// expiresAt must be positive and within the configured duration bounds.
// The execution fee rate is snapshotted into each new order.
// baseToken must be tokenIn (Sell) or tokenOut (Buy); it is emitted only as
// creation metadata and does not affect the order's execution terms.
// The caller must first approve Address() for makingAmount.
// Reverts while execution is halted for Limit orders.
func CreateOrder(
	cur realm,
	tokenIn string,
	tokenOut string,
	makingAmount int64,
	takingAmount int64,
	slippageBps int64,
	expiresAt int64,
	baseToken string,
) uint64 {
	return getImplementation().CreateOrder(0, cur, tokenIn, tokenOut, makingAmount, takingAmount, slippageBps, expiresAt, baseToken)
}

// CancelOrder refunds the remaining input and removes the order from the indexes.
// A past-deadline refund uses the expired event.
// It returns the refunded input.
//
// Owner only. Reverts while withdrawals are halted for limit orders.
func CancelOrder(cur realm, orderID uint64) int64 {
	return getImplementation().CancelOrder(0, cur, orderID)
}

// ExecuteOrder fills up to maxAmountIn through the order's token pair at poolFee.
// A nonzero sqrtPriceLimitX96 stops at that pool price and may leave input
// unspent in escrow. Zero requires maxAmountIn to be consumed in full.
// The order's minimum owner-net output is enforced on the actual input.
// Returns actual input and pool output before the order's execution fee;
// the owner is paid immediately after that fee is deducted.
// The immediate caller must be authorized for ExecuteOrder by the shared
// keeper policy. Reverts while execution or withdrawals are halted for limit orders.
func ExecuteOrder(cur realm, orderID uint64, maxAmountIn int64, poolFee uint32, sqrtPriceLimitX96 string) (int64, int64) {
	return getImplementation().ExecuteOrder(0, cur, orderID, maxAmountIn, poolFee, sqrtPriceLimitX96)
}

// CollectPendingExecutionFee forwards fees pending for tokenPath to the protocol
// fee realm without another fill. Anyone may call it; the caller receives nothing.
// Returns the amount forwarded and the amount left pending.
// Reverts while withdrawals are halted for Limit orders.
func CollectPendingExecutionFee(cur realm, tokenPath string) (int64, int64) {
	collector, ok := getImplementation().(pendingExecutionFeeCollector)
	if !ok {
		panic(errImplDoesNotSupportFeeCollection)
	}

	return collector.CollectPendingExecutionFee(0, cur, tokenPath)
}

// CleanupExpiredOrders refunds pending orders after their deadline.
// Anyone may call it.
//
// One call examines at most min(maxOrders, maxCleanupBatchSize) orders after
// startAfterOrderID, in ID order. It returns the number of orders expired and
// the cursor for the next call; repeat until the cursor is 0.
// Reverts while withdrawals are halted for limit orders.
func CleanupExpiredOrders(cur realm, startAfterOrderID uint64, maxOrders int) (int, uint64) {
	return getImplementation().CleanupExpiredOrders(0, cur, startAfterOrderID, maxOrders)
}

// CleanupExpiredOrdersByIDs refunds only the named expired orders.
// orderIDs is a strictly increasing comma-separated list of positive decimal
// order IDs. Existing unexpired or underfunded orders are returned for retry.
// Reverts while withdrawals are halted for limit orders.
func CleanupExpiredOrdersByIDs(cur realm, orderIDs string) (int, string) {
	cleanup, ok := getImplementation().(expiredOrderCleanup)
	if !ok {
		panic(errImplDoesNotSupportTargetedCleanup)
	}

	return cleanup.CleanupExpiredOrdersByIDs(0, cur, orderIDs)
}

// SetExecutionFeeRate sets the execution fee rate snapshotted into new orders,
// in basis points of gross output.
// Admin or governance only.
func SetExecutionFeeRate(cur realm, executionFeeRate int64) {
	getImplementation().SetExecutionFeeRate(0, cur, executionFeeRate)
}

// SetMinMakingAmount sets the minimum input amount for new orders, in raw token units.
// Existing orders are unaffected. Admin or governance only.
func SetMinMakingAmount(cur realm, minMakingAmount int64) {
	getImplementation().SetMinMakingAmount(0, cur, minMakingAmount)
}

// SetOrderDeadlines sets the allowed order duration range for new orders,
// in seconds. Admin or governance only.
func SetOrderDeadlines(cur realm, minDuration int64, maxDuration int64) {
	getImplementation().SetOrderDeadlines(0, cur, minDuration, maxDuration)
}

// SetMaxCleanupBatchSize caps the orders one CleanupExpiredOrders call examines,
// bounding its gas. Admin or governance only.
func SetMaxCleanupBatchSize(cur realm, maxCleanupBatchSize int64) {
	getImplementation().SetMaxCleanupBatchSize(0, cur, maxCleanupBatchSize)
}

// SetMaxSlippageBps sets the slippage cap for new orders in [0, 10000] bps.
// Existing orders keep their slippage. Admin or governance only.
func SetMaxSlippageBps(cur realm, maxSlippageBps int64) {
	getImplementation().SetMaxSlippageBps(0, cur, maxSlippageBps)
}
