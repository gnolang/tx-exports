// Package halt holds the halt switches shared by the GnoSwap order realms
// (gno.land/r/gnoswap/order/...).
//
// Each target (an order type such as "dca" or "limit") has a switch per
// operation. Admin or governance turns a switch on for one target, or for
// every target with TargetAll, and can add targets for new order realms.
// Order realms check IsHalted with their own target, which reports the
// operation halted when either switch is on, and decide which entry points
// each operation guards.
//
// Operations:
//   - OperationExecute: creating or executing orders
//   - OperationWithdraw: executing orders, paying out or refunding funds
//
// The switches are independent of the GnoSwap protocol halt levels.
package halt
