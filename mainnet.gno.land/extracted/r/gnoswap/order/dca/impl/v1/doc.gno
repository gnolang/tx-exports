// Package impl is the v0 implementation of the GnoSwap DCA order realm.
// It registers itself with gno.land/r/gnoswap/order/dca at init.
//
// Files:
//   - order.gno: CreateOrder, CancelOrder, Claim, ForceCancelOrder
//   - execute.gno: ExecuteGroup and the pool swap; rounds credit gross output
//   - execution_fee.gno: SetExecutionFeeRate, pending payout fees, and forwarding them to the protocol fee realm
//   - pool_selection.gno: choosing the pool of a round
//   - swap.gno: the pool swap of a round and its callback
//   - manager.gno: per-token minimum order sizes and pair price limits
//   - price_limit.gno: converting a pair price limit to a swap price limit
//   - claim_group_orders.gno: ClaimGroupOrders
//   - config.gno: admin configuration and slot steps
//   - getter.gno: read-only queries
//   - assert.gno, utils.gno: shared checks and helpers
//
// The executed amount is protected by the pair price limit the pool manager
// sets from an oracle price, which every quote and swap passes to the pool as
// its price limit, by the best-quote pool selection, and by the keeper's
// amountOutMin, quoted for the round's input. The price limit also bounds the
// ticks a quote or swap crosses, and so its gas. The execution gap keeps
// a group's next execution at least minExecutionGapRate of its interval after
// the previous one, even after a late execution.
// A round reverts unless it credits each of its orders at least the keeper's
// minOrderAmountOut, and never less than one unit, of output after its own
// execution fee rate. The order amount index sorts orders by fee rate, then
// amount, so the smallest order of each fee rate bounds every order of that rate.
// Roles: gno.land/r/gnoswap/order/keeper restricts executions and force cancellations
// to DCAKeeperRole, and the shared pool whitelist, token minimums, and price
// limits to PoolManagerRole, at deployment.
//
// Keepers earn storage deposits: each order stores one execution log per
// three rounds at creation, paid by its owner. Claim and ClaimGroupOrders
// release the order's logs whose rounds all executed and delete finished
// orders, which refunds the freed deposit to the transaction signer.
package impl
