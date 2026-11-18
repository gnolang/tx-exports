// Package limit holds the immutable building blocks of the GnoSwap limit
// order realm:
//
//   - types.gno: interfaces between the proxy and its implementations
//   - order.gno, config.gno: domain types stored by the realm
//   - math.gno: owner-net minimum output and cumulative execution-fee math
//   - keys.gno: B+tree key encodings
//   - consts.gno: basis-point denominator and domain bounds
//
// Nothing here owns realm state. Storage, authorization, and token transfers
// live in gno.land/r/gnoswap/order/limit and its implementations under impl/.
//
// Accounting: an order escrows makingAmount of tokenIn for takingAmount of
// tokenOut. Each fill must pay its owner at least
//
//	ceil(takingAmount * fillInput * (10000 - slippageBps) / (makingAmount * 10000))
//
// after the execution fee. The fee rate is snapshotted at creation; the total
// fee is floor(cumulativeGrossOutput * executionFeeRate / 10000). Each fill
// pays only the increase in that total, so splitting fills cannot reduce fees.
// Filled and refunded input are tracked separately; only the remaining input
// can be filled before expiry or refunded.
package limit
