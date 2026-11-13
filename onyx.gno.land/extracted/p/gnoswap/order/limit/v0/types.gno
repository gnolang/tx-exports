package limit

import (
	rotree "gno.land/p/nt/bptree/rotree/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

// These interfaces are the contract between the proxy realm
// gno.land/r/gnoswap/order/limit and its implementations.
// Keeping them in an immutable package lets every implementation version
// compile against the same definitions.

// ILimitOrder is the implementation interface behind the limit proxy.
type ILimitOrder interface {
	ILimitOrderManager
	ILimitOrderExecutor
	ILimitOrderAdmin
	ILimitOrderGetter
}

// ILimitOrderManager covers owner-facing order operations.
type ILimitOrderManager interface {
	// CreateOrder escrows makingAmount of tokenIn for takingAmount of tokenOut.
	// slippageBps=0 enforces the making/taking ratio or better.
	// expiresAt must be positive and within the configured duration bounds.
	// The execution fee rate is snapshotted from configuration.
	// baseToken must be tokenIn or tokenOut and is emitted as history metadata.
	CreateOrder(
		_ int,
		rlm realm,
		tokenIn string,
		tokenOut string,
		makingAmount int64,
		takingAmount int64,
		slippageBps int64,
		expiresAt int64,
		baseToken string,
	) uint64

	// CancelOrder refunds the remaining input to the owner. Owner only.
	// After the deadline, the refund is emitted as an expired refund.
	CancelOrder(_ int, rlm realm, orderID uint64) (refundIn int64)
}

// ILimitOrderExecutor covers keeper-authorized execution and public cleanup.
type ILimitOrderExecutor interface {
	// ExecuteOrder swaps at most maxAmountIn through the order's token pair
	// at poolFee. A nonzero sqrtPriceLimitX96 permits partial consumption; each fill
	// must still satisfy the order's owner-net minimum on its actual input.
	// Returns actual input and pool output before the order fee.
	ExecuteOrder(_ int, rlm realm, orderID uint64, maxAmountIn int64, poolFee uint32, sqrtPriceLimitX96 string) (actualInput int64, poolOutput int64)

	// CleanupExpiredOrders examines at most min(maxOrders, MaxCleanupBatchSize)
	// orders after startAfterOrderID in ID order and refunds expired ones.
	// It returns the number expired and the last examined ID while more
	// remain, or 0 when the scan is exhausted.
	CleanupExpiredOrders(_ int, rlm realm, startAfterOrderID uint64, maxOrders int) (expired int, nextCursor uint64)
}

// ILimitOrderAdmin covers admin/governance configuration.
// Changes apply to later operations, except where a method states otherwise.
type ILimitOrderAdmin interface {
	// SetExecutionFeeRate sets the execution fee rate snapshotted into new orders,
	// in basis points of gross output.
	SetExecutionFeeRate(_ int, rlm realm, executionFeeRate int64)
	// SetMaxSlippageBps sets the slippage cap for new orders, in [0, 10000] bps.
	SetMaxSlippageBps(_ int, rlm realm, maxSlippageBps int64)
	// SetMinMakingAmount sets the minimum input amount accepted for new orders.
	SetMinMakingAmount(_ int, rlm realm, minMakingAmount int64)
	// SetOrderDeadlines sets the allowed order duration range, in seconds.
	SetOrderDeadlines(_ int, rlm realm, minDuration int64, maxDuration int64)
	// SetMaxCleanupBatchSize caps the orders one CleanupExpiredOrders call examines.
	SetMaxCleanupBatchSize(_ int, rlm realm, maxCleanupBatchSize int64)
}

// ILimitOrderGetter exposes detached pending orders and read-only indexes.
type ILimitOrderGetter interface {
	GetConfig() *Config
	GetNextOrderID() uint64

	ExistsOrder(orderID uint64) bool
	// GetOrder returns a detached copy while pending, or nil after settlement.
	GetOrder(orderID uint64) *Order
	GetOrders() *rotree.ReadOnlyTree
	GetOrdersByOwner() *rotree.ReadOnlyTree

	GetPendingExecutionFeeAmount(tokenPath string) int64
	GetPendingExecutionFees() *rotree.ReadOnlyTree
}

// ILimitOrderStore is the persistent storage shared by all versions.
type ILimitOrderStore interface {
	HasOrders() bool
	GetOrders() *bptree.BPTree
	SetOrders(_ int, rlm realm, orders *bptree.BPTree) error

	HasOrdersByOwner() bool
	GetOrdersByOwner() *bptree.BPTree
	SetOrdersByOwner(_ int, rlm realm, ordersByOwner *bptree.BPTree) error

	HasPendingExecutionFees() bool
	GetPendingExecutionFees() *bptree.BPTree
	SetPendingExecutionFees(_ int, rlm realm, pendingExecutionFees *bptree.BPTree) error

	HasNextOrderID() bool
	GetNextOrderID() uint64
	SetNextOrderID(_ int, rlm realm, id uint64) error

	HasConfig() bool
	GetConfig() *Config
	SetConfig(_ int, rlm realm, config *Config) error
}
