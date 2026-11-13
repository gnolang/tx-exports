// Package keeper is the role-based access realm of the GnoSwap order realms.
//
// It owns a manager.State (gno.land/p/gnoswap/order/access/manager/v0).
// Roles are granted to keeper accounts, and each order realm function
// (target package path and selector) is assigned the role allowed to call
// it, or PublicRole for anyone.
//
// Administration is not a manager role: every management call is checked
// against the GnoSwap admin or governance (gno.land/r/gnoswap/access).
// manager.AdminRole is never granted here.
//
// Roles registered at deployment:
//   - DCAKeeperRole (1): DCA order keepers
//   - LimitKeeperRole (2): limit order keepers
//   - PoolManagerRole (3): DCA/Limit pool whitelist and DCA pool policy managers
//
// DCA ExecuteGroup and ForceCancelOrder are assigned to DCAKeeperRole at
// deployment, so only granted keepers run DCA rounds and force-cancel orders that
// block them. The whitelist realm's AddWhitelistedPool and RemoveWhitelistedPool,
// and DCA's SetTokenMinAmountPerExecution and SetPairPriceLimit are assigned to
// PoolManagerRole, so only granted managers pick the pools and the price
// limits rounds trade with (admin and governance may call them too).
// This role intentionally manages both targets' whitelists and DCA's token
// minimums and pair price limits; target-specific manager roles are not required.
// It does not grant ExecuteGroup, ForceCancelOrder, or ExecuteOrder.
// Keeping the two roles on separate accounts means a single leaked key
// cannot both choose a round's pool or price and run it.
//
// Admin or governance adds custom roles with AddRole.
//
// Order realms check authorization with IsAuthorized(target, selector,
// caller), passing their own package path, or with the non-crossing
// AssertIsAuthorizedCaller(0, cur, selector), which derives the target from cur.
package keeper
