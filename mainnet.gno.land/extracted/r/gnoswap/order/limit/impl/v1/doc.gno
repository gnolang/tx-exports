// Package impl is the v0 implementation of the GnoSwap limit order realm.
// It registers itself with gno.land/r/gnoswap/order/limit at init.
//
// Files:
//   - order.gno: CreateOrder, CancelOrder, CleanupExpiredOrders, CleanupExpiredOrdersByIDs
//   - execute.gno: ExecuteOrder, pool swaps, balance checks, and fill settlement
//   - execution_fee.gno: SetExecutionFeeRate, pending fees, and protocol fee collection
//   - swap.gno: swap price limits and pool amount decoding
//   - config.gno: admin configuration of order limits and cleanup batches
//   - getter.gno: read-only queries
//   - assert.gno, utils.gno: shared checks and helpers
//
// Each fill uses the keeper's pool fee tier on the order's token pair; the
// pool must be whitelisted for Limit orders. A zero sqrtPriceLimitX96 requires
// the entire maxAmountIn to be consumed; a nonzero limit permits partial
// consumption. Actual balance deltas must match the pool result, and the
// owner-net output must satisfy the order's slippage-adjusted ratio on the
// actual input, after the incremental cumulative execution fee.
//
// Filled orders are removed before paying the owner. Execution fees are
// forwarded to the protocol fee realm, or kept pending if collection is
// halted or rejected; later fills or CollectPendingExecutionFee retry them.
// Expired orders cannot be filled. Owner cancellation and public bounded
// cleanup refund unsold input and remove orders from both indexes.
// Roles: gno.land/r/gnoswap/order/keeper restricts ExecuteOrder to
// LimitKeeperRole at deployment. Admin or governance configures order limits
// and fees; PoolManagerRole manages the separate Limit pool whitelist through
// gno.land/r/gnoswap/order/whitelist.
package impl
