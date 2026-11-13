package limit

import (
	plimit "gno.land/p/gnoswap/order/limit/v0"
	rotree "gno.land/p/nt/bptree/rotree/v0"
)

// Getters return detached copies of stored values. Store trees are returned
// as read-only views keyed as in the store layout (see store.gno); views whose
// entries are pointers copy every entry they return. Callers page a view
// themselves through Iterate, IterateByOffset, or their reverse forms.

// ==================================
// Config Getters
// ==================================

// GetConfig returns a detached copy of the current global configuration.
//
// Returns:
//   - *plimit.Config: copy of the stored configuration
func GetConfig() *plimit.Config {
	return getImplementation().GetConfig()
}

// GetExecutionFeeRate returns the execution fee rate snapshotted into new orders.
//
// Returns:
//   - int64: execution fee rate, in basis points of gross output
func GetExecutionFeeRate() int64 {
	return GetConfig().ExecutionFeeRate()
}

// GetMaxSlippageBps returns the slippage cap for new orders.
//
// Returns:
//   - int64: maximum slippage, in basis points
func GetMaxSlippageBps() int64 {
	return GetConfig().MaxSlippageBps()
}

// GetMinMakingAmount returns the minimum input amount for new orders.
//
// Returns:
//   - int64: minimum makingAmount, in raw token units
func GetMinMakingAmount() int64 {
	return GetConfig().MinMakingAmount()
}

// GetOrderDeadlines returns the allowed order duration range for new orders.
//
// Returns:
//   - int64: shortest allowed expiresAt - createdAt, in seconds
//   - int64: longest allowed expiresAt - createdAt, in seconds
func GetOrderDeadlines() (int64, int64) {
	config := GetConfig()

	return config.MinOrderDuration(), config.MaxOrderDuration()
}

// GetMaxCleanupBatchSize returns the most orders one CleanupExpiredOrders call examines.
//
// Returns:
//   - int64: maximum cleanup batch size
func GetMaxCleanupBatchSize() int64 {
	return GetConfig().MaxCleanupBatchSize()
}

// ==================================
// Order Getters
// ==================================

// GetNextOrderID returns the ID the next created order receives.
//
// Returns:
//   - uint64: next order ID
func GetNextOrderID() uint64 {
	return getImplementation().GetNextOrderID()
}

// ExistsOrder reports whether an order is pending.
// Settled orders are deleted.
//
// Parameters:
//   - orderID: order to look up
//
// Returns:
//   - bool: true while the order is pending
func ExistsOrder(orderID uint64) bool {
	return getImplementation().ExistsOrder(orderID)
}

// GetOrder returns a detached pending order, or nil after it is settled.
//
// Parameters:
//   - orderID: order to look up
//
// Returns:
//   - *plimit.Order: copy of the order; nil when it is not pending
func GetOrder(orderID uint64) *plimit.Order {
	return getImplementation().GetOrder(orderID)
}

// GetOrders returns a live read-only view of pending orders.
//
// Returns:
//   - *rotree.ReadOnlyTree: plimit.OrderKey(orderID) -> *plimit.Order;
//     each order read from the view is detached from stored state
func GetOrders() *rotree.ReadOnlyTree {
	return getImplementation().GetOrders()
}

// GetOrdersByOwner returns the read-only owner index of pending orders.
// Iterate the [plimit.OwnerOrderPrefix(owner), plimit.PrefixEnd(prefix))
// range for one owner's orders in ID order, choosing the page size.
//
// Returns:
//   - *rotree.ReadOnlyTree: plimit.OwnerOrderKey(owner, orderID) -> uint64 orderID
func GetOrdersByOwner() *rotree.ReadOnlyTree {
	return getImplementation().GetOrdersByOwner()
}

// ==================================
// Execution Fee Getters
// ==================================

// GetPendingExecutionFeeAmount returns execution fees held for tokenPath until the
// protocol fee realm accepts them. A later fill with the same output token retries collection.
//
// Parameters:
//   - tokenPath: fee token path
//
// Returns:
//   - int64: pending execution fee, in raw token units
func GetPendingExecutionFeeAmount(tokenPath string) int64 {
	return getImplementation().GetPendingExecutionFeeAmount(tokenPath)
}

// GetPendingExecutionFees returns the read-only index of pending execution fees.
//
// Returns:
//   - *rotree.ReadOnlyTree: tokenPath -> int64 pending amount
func GetPendingExecutionFees() *rotree.ReadOnlyTree {
	return getImplementation().GetPendingExecutionFees()
}
