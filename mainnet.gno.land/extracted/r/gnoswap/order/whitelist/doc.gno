// Package whitelist manages the direct pools available to GnoSwap orders.
//
// DCA and Limit have independent pool whitelists, selected by TargetDCA
// ("dca") and TargetLimit ("limit"). Adding or removing a pool affects only
// the selected target. Pools must exist before being added; removing one
// prevents that target's orders from trading on it, not from cancelling.
//
// Admin, governance, or callers authorized by gno.land/r/gnoswap/order/keeper
// can update membership. At deployment, AddWhitelistedPool and
// RemoveWhitelistedPool are assigned to PoolManagerRole on this realm;
// the target argument selects the pool list, not the authorization policy.
// Queries expose membership, a read-only pool tree, and whether a pair has
// an existing whitelisted direct pool at any registered fee tier.
//
// Files:
//   - whitelist.gno: AddWhitelistedPool and RemoveWhitelistedPool
//   - getters.gno: read-only queries
//   - state.gno: independent DCA and Limit whitelist states
//   - assert.gno: authorization, target, and pool validation
//   - consts.gno: supported target names
//   - emits.gno: pool membership events
package whitelist
