package dca

// CreateOrder creates an order that sells amountPerExecution of inputToken
// for outputToken every interval seconds, executionCount times,
// and returns its ID.
//
// The caller must first approve Address()
// for amountPerExecution*executionCount.
// amountPerExecution must be at least GetMinAmountPerExecution(inputToken),
// and the pair direction needs a price limit (see SetPairPriceLimit).
// The order snapshots the execution fee rate in effect (see
// GetExecutionFeeRate) for its lifetime: the fee is that share of the order's
// output, deducted when the output is paid out. Later rate changes apply only
// to orders created afterwards.
// Orders with the same inputToken, outputToken, interval, and slotOffset
// share one group and execute together. Each round trades on the pair's
// best whitelisted pool, chosen at execution time (see GetExecutionQuote).
//
// The caller also pays the storage deposit of the order's execution logs,
// one per three rounds; each is refunded to whoever releases it after all of
// its rounds execute (see ClaimGroupOrders).
//
// Parameters:
//   - inputToken, outputToken: at least one whitelisted direct pool must
//     connect them (see gno.land/r/gnoswap/order/whitelist.AddWhitelistedPool).
//   - interval: one of GetConfig().AllowedIntervals().
//   - slotOffset: seconds after each interval boundary of the unix epoch at
//     which rounds run, a multiple of GetConfig().SlotStep(interval)
//     in [0, interval). Boundaries are UTC midnights for daily intervals;
//     weekly boundaries fall on Thursdays 00:00 UTC (1970-01-01 was one),
//     so a Monday slot is 4 days.
//     The first round waits for the next slot, or runs now if it is due.
//
// Reverts while the execute operation is halted for DCA
// in gno.land/r/gnoswap/order/halt.
func CreateOrder(
	cur realm,
	inputToken string,
	outputToken string,
	interval int64,
	slotOffset int64,
	amountPerExecution int64,
	executionCount int64,
) uint64 {
	return getImplementation().CreateOrder(0, cur, inputToken, outputToken, interval, slotOffset, amountPerExecution, executionCount)
}

// CancelOrder pays accrued output, refunds unsold input, and closes the order.
// It returns the refunded input and the output paid by this call.
//
// Owner only. Reverts while the withdraw operation is halted.
func CancelOrder(cur realm, orderID uint64) (int64, int64) {
	return getImplementation().CancelOrder(0, cur, orderID)
}

// Claim pays accrued output to the order owner and returns the amount.
// Anyone may call it, e.g. a keeper delivering output;
// proceeds always go to the owner.
// The order's execution logs whose rounds all executed are released,
// and their storage deposit is refunded to the caller.
//
// Reverts while the withdraw operation is halted.
func Claim(cur realm, orderID uint64) int64 {
	return getImplementation().Claim(0, cur, orderID)
}

// ExecuteGroup runs the next round of a group once it is due.
// Only accounts holding the DCA keeper role in gno.land/r/gnoswap/order/keeper
// may call it: the ExecuteGroup selector is assigned to DCAKeeperRole at
// deployment, and admin or governance grants the role or reassigns it.
// It returns the round input and the output credited to the orders,
// before their execution fees, which each order pays when paid out.
//
// Parameters:
//   - groupID: see GetExecutableGroups.
//   - amountOutMin: minimum pool output, before the execution fee;
//     0 disables it.
//   - expectedAmountIn: the group orderAmount amountOutMin was quoted for.
//     The round reverts if the orderAmount differs;
//     0 is accepted only with amountOutMin 0.
//   - minOrderAmountOut: the least output every order of the round must be
//     credited after its own execution fee rate
//     (see GetExecutionQuote), in the output token's smallest unit; 0 means 1.
//     The round reverts when its smallest order would receive less.
//
// Pool selection: among the pair's whitelisted pools (one per fee tier),
// the pool with the best quote for the full round is used.
// The round swaps on that pool directly through gno.land/r/gnoswap/pool,
// without the router, so no router fee is charged.
// The swap's price limit comes from the pair price limit
// (see SetPairPriceLimit), so no unit of input is sold below it,
// whatever amountOutMin is.
// The round reverts when no whitelisted pool can fill it within the limit.
//
// Reverts while the execute or withdraw operation is halted.
func ExecuteGroup(cur realm, groupID string, expectedAmountIn int64, amountOutMin int64, minOrderAmountOut int64) (int64, int64) {
	return getImplementation().ExecuteGroup(0, cur, groupID, expectedAmountIn, amountOutMin, minOrderAmountOut)
}

// ClaimGroupOrders pays accrued output to the owners of a group's active
// orders, as Claim does, so owners receive output without claiming.
// Anyone may call it; output always goes to the order owner.
//
// One call examines at most min(maxOrderCount, maxClaimBatchSize) orders
// after startAfterOrderID, in ID order. It returns the number of orders paid
// or completed and the cursor for the next call; repeat until the cursor is 0.
//
// Each order's execution logs whose rounds all executed are released and finished
// orders are deleted; the freed storage deposit is refunded to the caller,
// so the reward grows with the orders and rounds claimed.
//
// Reverts while the withdraw operation is halted.
func ClaimGroupOrders(cur realm, groupID string, startAfterOrderID uint64, maxOrderCount int) (int, uint64) {
	return getImplementation().ClaimGroupOrders(0, cur, groupID, startAfterOrderID, maxOrderCount)
}

// ForceCancelOrder closes an order that blocks its group's rounds. As with
// CancelOrder, accrued output and unsold input go to the order owner; the
// caller receives nothing but the freed storage deposit of the order's
// execution logs. It returns the refunded input and the output paid.
//
// The order must have rounds left and be, as checked on-chain:
//   - below the minimum per execution a new order of its token needs now
//     (reason below_min_amount), or
//   - in a due round that, as quoted now, credits it less than one output
//     unit after its execution fee (no_order_output), or
//   - the largest order (by amountPerExecution, ties included) of a due round
//     that no pool can fill as quoted now while a pool fills part of it,
//     with some output, within the price limit (exceeds_pool_capacity). A round that needs
//     several orders gone is shrunk one largest order per call.
//
// Any other order reverts with "order does not block its group".
// DCAOrderForceCancelled reports the reason.
//
// Only accounts holding the role assigned to the ForceCancelOrder selector in
// gno.land/r/gnoswap/order/keeper (DCAKeeperRole at deployment).
// Reverts while the withdraw operation is halted.
func ForceCancelOrder(cur realm, orderID uint64) (int64, int64) {
	return getImplementation().ForceCancelOrder(0, cur, orderID)
}

// CollectPendingExecutionFee forwards the execution fee pending for
// tokenPath (see GetPendingExecutionFeeAmount) to the protocol fee realm and
// returns the amount forwarded and the amount left pending.
// Payouts keep each order's execution fee as pending, and every round
// forwards the pending fee of its output token; this forwards it when no
// round of that output token runs. If the protocol fee realm rejects it,
// for example while its collection is halted, the fee stays pending.
// Anyone may call it: the fee only moves to the protocol fee realm.
//
// Reverts while the withdraw operation is halted.
func CollectPendingExecutionFee(cur realm, tokenPath string) (int64, int64) {
	return getImplementation().CollectPendingExecutionFee(0, cur, tokenPath)
}

// SetExecutionFeeRate sets the share of an order's output,
// in basis points (0 to 1000, at most 10%),
// sent to the protocol fee realm.
// Orders created afterwards snapshot it; existing orders keep their rate.
//
// Admin or governance only.
func SetExecutionFeeRate(cur realm, executionFeeRate int64) {
	getImplementation().SetExecutionFeeRate(0, cur, executionFeeRate)
}

// SetOrderLimits sets the minimum input per execution
// and the maximum executions per order. Admin or governance only.
func SetOrderLimits(cur realm, minAmountPerExecution int64, maxExecutionCount int64) {
	getImplementation().SetOrderLimits(0, cur, minAmountPerExecution, maxExecutionCount)
}

// AddAllowedInterval allows new orders to use interval, in seconds
// (one minute to one year). The interval starts with a single slot,
// offset 0 (see SetSlotStep). Admin or governance only.
func AddAllowedInterval(cur realm, interval int64) {
	getImplementation().AddAllowedInterval(0, cur, interval)
}

// RemoveAllowedInterval stops new orders from using interval.
// Existing orders and groups of that interval keep running until they finish;
// its slot step is dropped, and re-adding it starts from a single slot.
// At least one interval must stay allowed. Admin or governance only.
func RemoveAllowedInterval(cur realm, interval int64) {
	getImplementation().RemoveAllowedInterval(0, cur, interval)
}

// SetMinExecutionGapRate sets the minimum gap between two executions of a
// group, in basis points of its interval (0 to 10000), so a late execution is
// not followed right away by the next one. Admin or governance only.
func SetMinExecutionGapRate(cur realm, minExecutionGapRate int64) {
	getImplementation().SetMinExecutionGapRate(0, cur, minExecutionGapRate)
}

// SetMaxClaimBatchSize caps the orders one ClaimGroupOrders call examines,
// bounding its gas. Admin or governance only.
func SetMaxClaimBatchSize(cur realm, maxClaimBatchSize int64) {
	getImplementation().SetMaxClaimBatchSize(0, cur, maxClaimBatchSize)
}

// SetMaxPoolPriceDeviationRate sets how far, in basis points of price, a
// pool's price may sit on the favorable side of its swap price limit (see
// SetPairPriceLimit) and still be quoted, 0 to 10000; 0 disables the check.
// A pool further away is ineligible without a quote: its quote or swap would
// walk every tick between its price and the limit, which an empty or
// manipulated pool far from the oracle price makes unbounded.
// v0 starts at 2000 (20%). Admin or governance only.
func SetMaxPoolPriceDeviationRate(cur realm, maxPoolPriceDeviationRate int64) {
	getImplementation().SetMaxPoolPriceDeviationRate(0, cur, maxPoolPriceDeviationRate)
}

// SetMaxPairPriceLimitAge sets how long, in seconds, a pair price limit stays
// usable after the pool manager set it (see SetPairPriceLimit), 60 to 604800.
// Under an older limit every pool is ineligible (code price_limit_stale), so
// rounds stop until the limit is refreshed instead of trading at a stale price.
// v0 starts at 3600 (one hour). Admin or governance only.
func SetMaxPairPriceLimitAge(cur realm, maxPairPriceLimitAge int64) {
	getImplementation().SetMaxPairPriceLimitAge(0, cur, maxPairPriceLimitAge)
}

// SetSlotStep sets the spacing, in seconds, of the slot offsets new orders
// may use at interval: slotStep must divide the interval, and the interval
// then has interval/slotStep slots. slotStep == interval allows offset 0 only.
//
// Existing groups keep their slot, even one the new step no longer allows;
// only new orders are checked. Finer steps split each pair's orders into
// more groups, so each round sells less in more swaps.
//
// Admin or governance only.
func SetSlotStep(cur realm, interval int64, slotStep int64) {
	getImplementation().SetSlotStep(0, cur, interval, slotStep)
}

// SetTokenMinAmountPerExecution sets the minimum input per execution of new
// orders selling tokenPath, in raw token units, applied on top of the global
// minimum (see SetOrderLimits); 0 removes it.
// The pool manager derives it from an oracle price, so every order is worth a
// set value per round whatever the token's decimals.
// Existing orders are unaffected.
//
// Admin, governance, or accounts holding the role assigned to the
// SetTokenMinAmountPerExecution selector in gno.land/r/gnoswap/order/keeper
// (PoolManagerRole at deployment).
func SetTokenMinAmountPerExecution(cur realm, tokenPath string, minAmountPerExecution int64) {
	getImplementation().SetTokenMinAmountPerExecution(0, cur, tokenPath, minAmountPerExecution)
}

// SetPairPriceLimit sets the least pool output, before the execution fee,
// that rounds selling inputToken for outputToken accept per unit of input:
// minOutputPerInputX128 is raw outputToken units per raw inputToken unit,
// in Q128 fixed point, as a decimal string. "0" removes the limit.
//
// Every quote and round of the pair direction passes the limit to the pool
// as its swap price limit, adjusted for the pool's fee tier, so each unit of
// input fills at a rate of at least the limit and a swap crosses only the
// ticks up to it. A pool whose price is past the limit is skipped, and a
// round that cannot be filled within it reverts.
// A pair direction without a limit cannot be quoted, executed,
// or receive new orders.
// The limit applies from the next quote or round, to existing orders too.
// Its update time is recorded but not checked on-chain.
//
// Admin, governance, or accounts holding the role assigned to the
// SetPairPriceLimit selector in gno.land/r/gnoswap/order/keeper
// (PoolManagerRole at deployment).
func SetPairPriceLimit(cur realm, inputToken string, outputToken string, minOutputPerInputX128 string) {
	getImplementation().SetPairPriceLimit(0, cur, inputToken, outputToken, minOutputPerInputX128)
}
