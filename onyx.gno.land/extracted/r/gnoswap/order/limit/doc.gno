// Package limit is the GnoSwap limit order realm.
//
// Users escrow makingAmount of tokenIn for takingAmount of tokenOut before
// expiresAt. Authorized keepers fill orders on a whitelisted direct pool,
// without the router, choosing the pool fee tier and swap price limit for
// each fill. Partial fills leave unsold input in escrow; each fill pays the
// owner immediately after deducting the order's snapshotted execution fee,
// while enforcing the order's slippage-adjusted owner-net exchange ratio.
// Owners can cancel for the remaining input, and anyone can refund expired
// orders through bounded cleanup. Settled orders are removed from the indexes.
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
//   - swap_callback.gno: authenticated pool callback paying escrowed input
package limit
