package whitelist

import (
	"gno.land/r/gnoswap/order/keeper"
)

// AddWhitelistedPool permits target's orders to trade on an existing pool.
// Admin, governance, or the role assigned to this selector may call it.
func AddWhitelistedPool(cur realm, target, poolPath string) {
	prev := assertIsManagerCall(0, cur, keeper.SelectorAddWhitelistedPool)
	state := getState(target)

	assertIsExistingPool(poolPath)
	assertIsNotWhitelistedPool(state, target, poolPath)

	state.AddPool(poolPath)
	emitPoolUpdated(0, prev, target, poolPath, true)
}

// RemoveWhitelistedPool stops only target's orders from using this pool.
// Existing orders remain cancellable. Authorization matches AddWhitelistedPool.
func RemoveWhitelistedPool(cur realm, target, poolPath string) {
	prev := assertIsManagerCall(0, cur, keeper.SelectorRemoveWhitelistedPool)
	state := getState(target)
	assertIsWhitelistedPool(state, target, poolPath)

	state.RemovePool(poolPath)
	emitPoolUpdated(0, prev, target, poolPath, false)
}
