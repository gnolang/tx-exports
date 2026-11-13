package dca

import (
	pdca "gno.land/p/gnoswap/order/dca/v0"
	rotree "gno.land/p/nt/bptree/rotree/v0"
)

// Getters return copies of stored values. Store trees are returned as
// read-only views keyed as in the store layout (see store.gno); views whose
// entries are pointers copy every entry they return. Callers page a view
// themselves through Iterate, IterateByOffset, or their reverse forms.

// ==================================
// Config Getters
// ==================================

// GetConfig returns a copy of the configuration.
//
// Returns:
//   - *pdca.Config: copy of the stored configuration
func GetConfig() *pdca.Config {
	return getImplementation().GetConfig()
}

// GetExecutionFeeRate returns the execution fee rate new orders snapshot:
// the share of an order's output sent to the protocol fee realm.
// An existing order's rate is pdca.Order.ExecutionFeeRate (see GetOrder).
//
// Returns:
//   - int64: execution fee rate, in basis points
func GetExecutionFeeRate() int64 {
	return GetConfig().ExecutionFeeRate()
}

// GetMaxPoolPriceDeviationRate returns how far, in basis points of price, a
// pool's price may sit on the favorable side of its swap price limit and still
// be quoted (see SetMaxPoolPriceDeviationRate); 0 means the check is off.
//
// Returns:
//   - int64: rate in basis points
func GetMaxPoolPriceDeviationRate() int64 {
	return GetConfig().MaxPoolPriceDeviationRate()
}

// GetMaxPairPriceLimitAge returns how long, in seconds, a pair price limit
// stays usable after it was set (see SetMaxPairPriceLimitAge).
//
// Returns:
//   - int64: maximum age in seconds
func GetMaxPairPriceLimitAge() int64 {
	return GetConfig().MaxPairPriceLimitAge()
}

// GetMaxExecutionCount returns the maximum executions of a new order.
//
// Returns:
//   - int64: maximum executionCount
func GetMaxExecutionCount() int64 {
	return GetConfig().MaxExecutionCount()
}

// GetAllowedIntervals returns the intervals new orders may use.
//
// Returns:
//   - []int64: allowed intervals in seconds, ascending
func GetAllowedIntervals() []int64 {
	return GetConfig().AllowedIntervals()
}

// IsAllowedInterval reports whether new orders may use interval.
//
// Parameters:
//   - interval: round interval, in seconds
//
// Returns:
//   - bool: true when interval is allowed
func IsAllowedInterval(interval int64) bool {
	return GetConfig().IsAllowedInterval(interval)
}

// GetSlotStep returns the spacing of the slot offsets new orders may use at interval.
//
// Parameters:
//   - interval: round interval, in seconds
//
// Returns:
//   - int64: slot step in seconds; 0 when interval is not allowed
func GetSlotStep(interval int64) int64 {
	return GetConfig().SlotStep(interval)
}

// GetMinExecutionGapRate returns the minimum gap between a group's executions.
//
// Returns:
//   - int64: minimum gap, in basis points of the group interval
func GetMinExecutionGapRate() int64 {
	return GetConfig().MinExecutionGapRate()
}

// GetMaxClaimBatchSize returns the most orders one ClaimGroupOrders call examines.
//
// Returns:
//   - int64: maximum claim batch size
func GetMaxClaimBatchSize() int64 {
	return GetConfig().MaxClaimBatchSize()
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

// ExistsOrder reports whether an order is active.
// Finished orders are deleted.
//
// Parameters:
//   - orderID: order to look up
//
// Returns:
//   - bool: true while the order is active
func ExistsOrder(orderID uint64) bool {
	return getImplementation().ExistsOrder(orderID)
}

// GetOrder returns a copy of an active order.
// Finished orders are deleted and return an error.
//
// Parameters:
//   - orderID: order to look up
//
// Returns:
//   - *pdca.Order: copy of the order
//   - error: non-nil when the order is not active
func GetOrder(orderID uint64) (*pdca.Order, error) {
	return getImplementation().GetOrder(orderID)
}

// GetOrders returns a read-only view of active orders.
//
// Returns:
//   - *rotree.ReadOnlyTree: pdca.OrderKey(orderID) -> *pdca.Order;
//     each order read from the view is a copy
func GetOrders() *rotree.ReadOnlyTree {
	return getImplementation().GetOrders()
}

// GetOrdersByOwner returns the read-only owner index of active orders.
// Iterate the [pdca.OwnerOrderPrefix(owner), pdca.PrefixEnd(prefix)) range
// for one owner's orders in ID order.
//
// Returns:
//   - *rotree.ReadOnlyTree: pdca.OwnerOrderKey(owner, orderID) -> uint64 orderID
func GetOrdersByOwner() *rotree.ReadOnlyTree {
	return getImplementation().GetOrdersByOwner()
}

// GetOrderIDsByOwner returns up to count active order IDs of owner,
// ascending and greater than startAfterID (0 starts from the first).
// Page by passing the last returned ID.
//
// Parameters:
//   - owner: order owner
//   - startAfterID: exclusive lower bound of the returned IDs
//   - count: maximum number of IDs returned
//
// Returns:
//   - []uint64: active order IDs, ascending
func GetOrderIDsByOwner(owner address, startAfterID uint64, count int) []uint64 {
	return getImplementation().GetOrderIDsByOwner(owner, startAfterID, count)
}

// GetClaimableAmount returns the output an order can claim now,
// net of the order's execution fee.
//
// Parameters:
//   - orderID: order to look up
//
// Returns:
//   - int64: output the next Claim pays the owner; 0 when the order is not active
func GetClaimableAmount(orderID uint64) int64 {
	return getImplementation().GetClaimableAmount(orderID)
}

// GetOrderExecutionLogs returns copies of up to count of an active order's
// unreleased execution logs, oldest first: each covers up to three rounds,
// [FirstRound, LastRound], and the input the order sells in each. A log is
// released once all of its rounds executed and the order is claimed;
// the rounds' swap results are in the DCAGroupExecuted events.
//
// Parameters:
//   - orderID: order to look up
//   - count: maximum number of logs returned
//
// Returns:
//   - []*pdca.ExecutionLog: copies of the order's unreleased logs
//   - error: non-nil when the order is not active
func GetOrderExecutionLogs(orderID uint64, count int) ([]*pdca.ExecutionLog, error) {
	return getImplementation().GetOrderExecutionLogs(orderID, count)
}

// GetExecutionLogs returns the read-only index of unreleased execution logs.
// Iterate the [pdca.ExecutionLogPrefix(orderID), pdca.PrefixEnd(prefix))
// range for one order's logs; the key suffix decodes to the first round.
//
// Returns:
//   - *rotree.ReadOnlyTree: pdca.ExecutionLogKey(orderID, firstRound) -> uint64 lastRound
func GetExecutionLogs() *rotree.ReadOnlyTree {
	return getImplementation().GetExecutionLogs()
}

// ==================================
// Group Getters
// ==================================

// ExistsGroup reports whether a group is stored.
//
// Parameters:
//   - groupID: pdca.MakeGroupID(inputToken, outputToken, interval, slotOffset)
//
// Returns:
//   - bool: true when the group exists
func ExistsGroup(groupID string) bool {
	return getImplementation().ExistsGroup(groupID)
}

// GetGroup returns a copy of a group without its round marks.
// The copy's round mark tree is empty; read the marks through GetGroupRoundMarks.
//
// Parameters:
//   - groupID: group to look up
//
// Returns:
//   - *pdca.Group: copy of the group's fields
//   - error: non-nil when the group does not exist
func GetGroup(groupID string) (*pdca.Group, error) {
	return getImplementation().GetGroup(groupID)
}

// GetGroups returns a read-only view of every group.
//
// Returns:
//   - *rotree.ReadOnlyTree: groupID -> *pdca.Group; each group read from
//     the view is a copy without its round marks, as GetGroup returns
func GetGroups() *rotree.ReadOnlyTree {
	return getImplementation().GetGroups()
}

// GetGroupRoundMarks returns a read-only view of a group's round marks:
// one per round at which an unfinalized order ends.
//
// Parameters:
//   - groupID: group to look up
//
// Returns:
//   - *rotree.ReadOnlyTree: pdca.RoundKey(round) -> *pdca.RoundMark; each
//     mark read from the view is a copy. nil when the group does not exist
func GetGroupRoundMarks(groupID string) *rotree.ReadOnlyTree {
	return getImplementation().GetGroupRoundMarks(groupID)
}

// GetOrdersByGroup returns the read-only group index of active orders.
// Iterate the [pdca.GroupOrderPrefix(groupID), pdca.PrefixEnd(prefix))
// range for one group's orders in ID order.
//
// Returns:
//   - *rotree.ReadOnlyTree: pdca.GroupOrderKey(groupID, orderID) -> uint64 orderID
func GetOrdersByGroup() *rotree.ReadOnlyTree {
	return getImplementation().GetOrdersByGroup()
}

// GetOrderAmountsByGroup returns the read-only group index of orders by
// executionFeeRate, then amountPerExecution, which a round reads for the
// smallest order of each fee rate.
// Iterate the [pdca.GroupOrderPrefix(groupID), pdca.PrefixEnd(prefix))
// range for one group's orders by ascending executionFeeRate,
// amountPerExecution, then ID, or the
// [pdca.GroupOrderFeeRatePrefix(groupID, rate), pdca.PrefixEnd(prefix))
// range for the orders of one fee rate.
// A finished order's entry stays until the order is paid out
// or a later round of its group removes it.
//
// Returns:
//   - *rotree.ReadOnlyTree: pdca.GroupOrderAmountKey(groupID, executionFeeRate, amountPerExecution, orderID) -> uint64 endRound
func GetOrderAmountsByGroup() *rotree.ReadOnlyTree {
	return getImplementation().GetOrderAmountsByGroup()
}

// GetOrderIDsByGroup returns up to count active order IDs of a group,
// ascending and greater than startAfterID. Page as GetOrderIDsByOwner.
//
// Parameters:
//   - groupID: group to look up
//   - startAfterID: exclusive lower bound of the returned IDs
//   - count: maximum number of IDs returned
//
// Returns:
//   - []uint64: active order IDs, ascending
func GetOrderIDsByGroup(groupID string, startAfterID uint64, count int) []uint64 {
	return getImplementation().GetOrderIDsByGroup(groupID, startAfterID, count)
}

// GetScheduledGroups returns the read-only schedule of groups with input to
// sell, ordered by next execution timestamp, then group ID.
// pdca.ScheduleKeyTimestamp decodes a key's timestamp.
//
// Returns:
//   - *rotree.ReadOnlyTree: pdca.ScheduleKey(nextExecutionTimestamp, groupID) -> string groupID
func GetScheduledGroups() *rotree.ReadOnlyTree {
	return getImplementation().GetScheduledGroups()
}

// GetExecutableGroups returns copies of up to count groups due now,
// oldest first.
//
// Paging: start with cursor "",
// then pass pdca.FormatScheduleCursor of the last group back
// until fewer than count groups return.
// The cursor is a fixed schedule position,
// so groups executed between pages do not shift it.
//
// Parameters:
//   - cursor: "" or "<nextExecutionTimestamp>|<groupID>" of the last group seen
//   - count: maximum number of groups returned
//
// Returns:
//   - []*pdca.Group: copies of due groups without their round marks;
//     empty while execution is halted
//   - error: non-nil when cursor is malformed
func GetExecutableGroups(cursor string, count int) ([]*pdca.Group, error) {
	return getImplementation().GetExecutableGroups(cursor, count)
}

// GetExecutionQuote returns, as JSON, how the group's next round would trade
// now: its input, the selected pool, the expected pool output, an estimate
// of the orders' execution fees on that output and of what is left for the
// orders, and every candidate pool's quote or ineligibility reason.
// Orders pay their own snapshotted fee rates when paid out, each rounding
// its own cumulative fee. The fee and order output totals instead charge
// executionFeeRate, the highest rate of the orders the round sells (0 when
// none does), once on the whole output, so they are estimates, not bounds:
// the fees the orders pay can exceed expectedExecutionFeeAmount by rounding.
// minAmountsByExecutionFeeRate lists, by ascending fee rate, the smallest
// order of each rate the round sells. The round reverts unless every listed
// order is credited at least max(1, minOrderAmountOut) net of its rate;
// expectedMinOrderAmountOut is the least such output at expectedAmountOut,
// and minAmountPerExecution the smallest order overall.
// Keepers set amountOutMin from expectedAmountOut
// and pass amountIn as expectedAmountIn.
//
// Parameters:
//   - groupID: group to quote
//
// Returns:
//   - string: JSON quote; "" when the group does not exist
func GetExecutionQuote(groupID string) string {
	return getImplementation().GetExecutionQuote(groupID)
}

// ==================================
// Manager Setting Getters
// ==================================

// GetTokenMinAmountPerExecution returns the minimum input per execution the
// manager set for tokenPath (see SetTokenMinAmountPerExecution).
//
// Parameters:
//   - tokenPath: input token path
//
// Returns:
//   - int64: minimum in raw token units; 0 when none is set
func GetTokenMinAmountPerExecution(tokenPath string) int64 {
	return getImplementation().GetTokenMinAmountPerExecution(tokenPath)
}

// GetMinAmountPerExecution returns the minimum input per execution a new
// order selling tokenPath needs: the larger of GetConfig().MinAmountPerExecution()
// and GetTokenMinAmountPerExecution(tokenPath).
//
// Parameters:
//   - tokenPath: input token path
//
// Returns:
//   - int64: effective minimum, in raw token units
func GetMinAmountPerExecution(tokenPath string) int64 {
	return getImplementation().GetMinAmountPerExecution(tokenPath)
}

// GetTokenMinAmountsPerExecution returns the read-only index of per-token
// minimums, in key order.
//
// Returns:
//   - *rotree.ReadOnlyTree: tokenPath -> int64
func GetTokenMinAmountsPerExecution() *rotree.ReadOnlyTree {
	return getImplementation().GetTokenMinAmountsPerExecution()
}

// GetPairPriceLimit returns the price limit of selling inputToken for
// outputToken (see SetPairPriceLimit).
//
// Parameters:
//   - inputToken, outputToken: the pair direction
//
// Returns:
//   - string: minOutputPerInputX128, decimal Q128; "0" when none is set
//   - int64: unix time the limit was set; 0 when none is set
func GetPairPriceLimit(inputToken string, outputToken string) (string, int64) {
	limit, found := getImplementation().GetPairPriceLimit(inputToken, outputToken)
	if !found {
		return "0", 0
	}

	return limit.MinOutputPerInputX128().ToString(), limit.UpdatedAt()
}

// GetPairPriceLimits returns a read-only view of the pair price limits,
// in key order. Entries are copies.
//
// Returns:
//   - *rotree.ReadOnlyTree: "inputToken:outputToken" -> *pdca.PairPriceLimit
func GetPairPriceLimits() *rotree.ReadOnlyTree {
	return getImplementation().GetPairPriceLimits()
}

// ==================================
// Execution Fee Getters
// ==================================

// GetPendingExecutionFeeAmount returns the execution fee of tokenPath held
// by this realm: fees payouts charged, and fees the protocol fee realm could
// not accept yet. It is forwarded by the next round whose output token is
// tokenPath, or by CollectPendingExecutionFee.
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
// A token whose pending fee was forwarded keeps its entry at 0.
//
// Returns:
//   - *rotree.ReadOnlyTree: tokenPath -> int64 pending amount
func GetPendingExecutionFees() *rotree.ReadOnlyTree {
	return getImplementation().GetPendingExecutionFees()
}
