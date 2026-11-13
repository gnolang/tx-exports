package dca

import (
	rotree "gno.land/p/nt/bptree/rotree/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

// These interfaces are the contract between the proxy realm
// gno.land/r/gnoswap/order/dca and its implementations.
// Keeping them in an immutable package lets every implementation version
// compile against the same definitions.

// IDCAOrder is the implementation interface behind the order/dca proxy.
type IDCAOrder interface {
	IDCAOrderManager
	IDCAOrderExecutor
	IDCAOrderAdmin
	IDCAOrderGetter
}

// IDCAOrderManager covers owner-facing order operations.
type IDCAOrderManager interface {
	// CreateOrder escrows amountPerExecution*executionCount of inputToken,
	// and joins the (inputToken, outputToken, interval, slotOffset) group.
	CreateOrder(
		_ int,
		rlm realm,
		inputToken string,
		outputToken string,
		interval int64,
		slotOffset int64,
		amountPerExecution int64,
		executionCount int64,
	) uint64

	// CancelOrder pays accrued output, refunds unsold input,
	// and closes the order. Owner only.
	CancelOrder(_ int, rlm realm, orderID uint64) (refundedAmount int64, claimedAmount int64)

	// Claim pays accrued output to the order owner. Anyone may call it.
	Claim(_ int, rlm realm, orderID uint64) (claimedAmount int64)
}

// IDCAOrderExecutor covers keeper-authorized execution and cancellation,
// and public batch-claim entry points.
type IDCAOrderExecutor interface {
	// ExecuteGroup sells the group's per-round input with a pool swap,
	// on the pool with the best quote, and credits the output to the orders;
	// each order's execution fee is deducted when it is paid out.
	// amountOutMin (0 disables it) is the pool output floor
	// quoted for expectedAmountIn.
	// If the group orderAmount differs from expectedAmountIn,
	// the round reverts so the keeper can quote again.
	// Passing 0 for both runs the round without a floor.
	// Every order of the round must be credited at least
	// max(1, minOrderAmountOut) of output after its own execution fee
	// rate, or the round reverts.
	ExecuteGroup(
		_ int,
		rlm realm,
		groupID string,
		expectedAmountIn int64,
		amountOutMin int64,
		minOrderAmountOut int64,
	) (executedAmountIn int64, executedAmountOut int64)

	// ClaimGroupOrders pays accrued output to the owners of up to
	// maxOrderCount orders of a group, after startAfterOrderID in ID order.
	// It returns the number of orders paid or completed,
	// and the cursor for the next call (0 when the group is done).
	ClaimGroupOrders(_ int, rlm realm, groupID string, startAfterOrderID uint64, maxOrderCount int) (claimedOrderCount int, nextCursor uint64)

	// ForceCancelOrder closes an order that blocks its group's rounds,
	// as CancelOrder does for its owner: accrued output and unsold input
	// go to the owner. The implementation checks on-chain that the order
	// blocks its group and rejects any other. Keeper role only.
	ForceCancelOrder(_ int, rlm realm, orderID uint64) (refundedAmount int64, claimedAmount int64)

	// CollectPendingExecutionFee forwards the execution fee pending for
	// tokenPath to the protocol fee realm. Anyone may call it.
	CollectPendingExecutionFee(_ int, rlm realm, tokenPath string) (forwardedAmount int64, pendingAmount int64)
}

// IDCAOrderAdmin covers admin or governance operations.
// Every rate is in basis points of BasisPointDenominator.
type IDCAOrderAdmin interface {
	// SetExecutionFeeRate sets the share of an order's gross output,
	// in basis points, sent to the protocol fee realm.
	// Orders snapshot it at creation; existing orders keep their rate.
	SetExecutionFeeRate(_ int, rlm realm, executionFeeRate int64)

	// AddAllowedInterval and RemoveAllowedInterval manage the intervals new
	// orders may use; existing orders keep their interval.
	AddAllowedInterval(_ int, rlm realm, interval int64)
	RemoveAllowedInterval(_ int, rlm realm, interval int64)
	// SetOrderLimits sets the minimum input per execution
	// and the maximum executions per order.
	SetOrderLimits(_ int, rlm realm, minAmountPerExecution int64, maxExecutionCount int64)

	// SetMinExecutionGapRate sets the minimum gap between a group's
	// executions, in basis points of its interval.
	SetMinExecutionGapRate(_ int, rlm realm, minExecutionGapRate int64)

	// SetMaxClaimBatchSize caps the orders one ClaimGroupOrders call examines.
	SetMaxClaimBatchSize(_ int, rlm realm, maxClaimBatchSize int64)

	// SetMaxPoolPriceDeviationRate sets how far, in basis points of price, a
	// pool's price may sit on the favorable side of its swap price limit and
	// still be quoted; 0 disables the check.
	SetMaxPoolPriceDeviationRate(_ int, rlm realm, maxPoolPriceDeviationRate int64)

	// SetMaxPairPriceLimitAge sets how long, in seconds, a pair price limit
	// stays usable after it was set.
	SetMaxPairPriceLimitAge(_ int, rlm realm, maxPairPriceLimitAge int64)

	// SetSlotStep sets the spacing of the slot offsets
	// new orders may use at interval.
	SetSlotStep(_ int, rlm realm, interval int64, slotStep int64)

	// SetTokenMinAmountPerExecution sets the minimum input per execution of
	// orders selling tokenPath, on top of the global minimum; 0 removes it.
	// Admin, governance, or the manager role assigned to the selector.
	SetTokenMinAmountPerExecution(_ int, rlm realm, tokenPath string, minAmountPerExecution int64)

	// SetPairPriceLimit sets the minimum pool output per unit of input,
	// in Q128, of rounds selling inputToken for outputToken; "0" removes it.
	// A pair direction without a limit cannot be quoted, executed,
	// or receive new orders.
	// Admin, governance, or the manager role assigned to the selector.
	SetPairPriceLimit(_ int, rlm realm, inputToken string, outputToken string, minOutputPerInputX128 string)
}

// IDCAOrderGetter covers read-only queries.
// Returned orders, groups, and configs are copies of the stored state.
// Store trees are exposed as read-only views keyed as in the store layout;
// entries that are pointers are copied on every read.
type IDCAOrderGetter interface {
	GetConfig() *Config
	GetNextOrderID() uint64

	ExistsOrder(orderID uint64) bool
	GetOrder(orderID uint64) (*Order, error)
	GetOrders() *rotree.ReadOnlyTree
	GetOrdersByOwner() *rotree.ReadOnlyTree
	GetOrderIDsByOwner(owner address, startAfterID uint64, count int) []uint64
	GetClaimableAmount(orderID uint64) int64
	GetOrderExecutionLogs(orderID uint64, count int) ([]*ExecutionLog, error)
	GetExecutionLogs() *rotree.ReadOnlyTree

	ExistsGroup(groupID string) bool
	GetGroup(groupID string) (*Group, error)
	GetGroups() *rotree.ReadOnlyTree
	GetGroupRoundMarks(groupID string) *rotree.ReadOnlyTree
	GetOrdersByGroup() *rotree.ReadOnlyTree
	GetOrderAmountsByGroup() *rotree.ReadOnlyTree
	GetOrderIDsByGroup(groupID string, startAfterID uint64, count int) []uint64
	GetScheduledGroups() *rotree.ReadOnlyTree
	GetExecutableGroups(cursor string, count int) ([]*Group, error)
	GetExecutionQuote(groupID string) string

	GetTokenMinAmountPerExecution(tokenPath string) int64
	GetMinAmountPerExecution(tokenPath string) int64
	GetTokenMinAmountsPerExecution() *rotree.ReadOnlyTree
	GetPairPriceLimit(inputToken string, outputToken string) (*PairPriceLimit, bool)
	GetPairPriceLimits() *rotree.ReadOnlyTree

	GetPendingExecutionFeeAmount(tokenPath string) int64
	GetPendingExecutionFees() *rotree.ReadOnlyTree
}

// IDCAOrderStore is the persistent storage shared by all versions.
type IDCAOrderStore interface {
	HasOrders() bool
	GetOrders() *bptree.BPTree
	SetOrders(_ int, rlm realm, orders *bptree.BPTree) error

	HasOrdersByOwner() bool
	GetOrdersByOwner() *bptree.BPTree
	SetOrdersByOwner(_ int, rlm realm, ordersByOwner *bptree.BPTree) error

	HasGroups() bool
	GetGroups() *bptree.BPTree
	SetGroups(_ int, rlm realm, groups *bptree.BPTree) error

	HasScheduledGroups() bool
	GetScheduledGroups() *bptree.BPTree
	SetScheduledGroups(_ int, rlm realm, groups *bptree.BPTree) error

	HasNextOrderID() bool
	GetNextOrderID() uint64
	SetNextOrderID(_ int, rlm realm, id uint64) error

	HasConfig() bool
	GetConfig() *Config
	SetConfig(_ int, rlm realm, config *Config) error

	IsExecuting() bool
	SetExecuting(_ int, rlm realm, executing bool) error

	HasOrdersByGroup() bool
	GetOrdersByGroup() *bptree.BPTree
	SetOrdersByGroup(_ int, rlm realm, ordersByGroup *bptree.BPTree) error

	HasPendingExecutionFees() bool
	GetPendingExecutionFees() *bptree.BPTree
	SetPendingExecutionFees(_ int, rlm realm, pendingExecutionFees *bptree.BPTree) error

	HasExecutionLogs() bool
	GetExecutionLogs() *bptree.BPTree
	SetExecutionLogs(_ int, rlm realm, executionLogs *bptree.BPTree) error

	HasOrderAmountsByGroup() bool
	GetOrderAmountsByGroup() *bptree.BPTree
	SetOrderAmountsByGroup(_ int, rlm realm, orderAmountsByGroup *bptree.BPTree) error

	HasTokenMinAmountsPerExecution() bool
	GetTokenMinAmountsPerExecution() *bptree.BPTree
	SetTokenMinAmountsPerExecution(_ int, rlm realm, tokenMinAmounts *bptree.BPTree) error

	HasPairPriceLimits() bool
	GetPairPriceLimits() *bptree.BPTree
	SetPairPriceLimits(_ int, rlm realm, pairPriceLimits *bptree.BPTree) error
}
