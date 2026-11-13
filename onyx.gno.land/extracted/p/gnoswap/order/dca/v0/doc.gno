// Package dca holds the immutable building blocks of the GnoSwap DCA
// (dollar-cost averaging) order realm:
//
//   - types.gno: interfaces between the proxy and its implementations
//   - order.gno, group.gno, config.gno: domain types stored by the realm
//   - math.gno: scheduling, accumulator, fee, and payout math
//   - keys.gno: B+tree key encodings
//
// Nothing here holds state. Storage, authorization, and token transfers live
// in gno.land/r/gnoswap/order/dca and its implementations under impl/.
//
// Accounting: orders selling the same token for the same token at the same
// interval and slot offset share a group. A group's rounds run at the unix
// times t with t % interval == slotOffset, so the slot fixes the time of day
// (or day of week) of every round. Each round sells the sum of the active orders'
// per-round input and adds the whole output per unit of input, scaled by
// 2^128, to the group accumulator. An order accrues
//
//	amountPerExecution * (acc(endRound) - debtX128) / 2^128
//
// of gross output, rounded down, where debtX128 starts at the accumulator when
// the order joins. A payout moves debtX128 only by the accumulator share its
// gross output pays for, so the remainder below one unit stays owed and is
// paid once later rounds add it up to a whole unit.
// Each payout deducts the order's execution fee, at the rate it snapshotted
// when created, from that gross output (see CalculatePayoutExecutionFeeAmount).
package dca
