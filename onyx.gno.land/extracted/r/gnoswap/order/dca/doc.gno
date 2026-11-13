// Package dca is the GnoSwap DCA (dollar-cost averaging) order realm.
//
// Users escrow inputToken and sell amountPerExecution of it for outputToken
// every interval, executionCount times, at a chosen slot of the interval
// (e.g. 09:00 UTC daily). Orders of the same pair, interval, and slot
// form a group that keepers execute in one pool swap per round, on the
// pair's best whitelisted pool, without the router. Each round's swap output
// accrues to the orders and is paid by Claim, or by keepers through
// ClaimGroupOrders; each payout deducts the execution fee at the rate the
// order snapshotted when it was created.
//
// This package is the permanent entry point. It owns the escrow address, the
// KV store shared by every version, and the upgrade switch; the business
// logic lives in a registered implementation (impl/v0).
//
// Files:
//   - proxy.gno: state-changing entry points
//   - getter.gno: read-only queries
//   - store.gno: KV store and store keys
//   - state.gno: realm state and the active implementation
//   - upgrade.gno: implementation registration and upgrades
package dca
