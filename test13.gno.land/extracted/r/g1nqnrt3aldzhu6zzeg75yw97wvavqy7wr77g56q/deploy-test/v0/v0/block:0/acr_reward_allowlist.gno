package block

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const (
	SetAcrRewardEnabledEvent   = "SetAcrRewardEnabled"
	UnsetAcrRewardEnabledEvent = "UnsetAcrRewardEnabled"
)

// SetAcrRewardEnabled enables ACR reward for a block (Admin only)
func SetAcrRewardEnabled(cur realm, blockID uint32) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	blockIDStr := blockIDToString(blockID)
	blockStore.SetAcrRewardEnabled(blockID)

	chain.Emit(SetAcrRewardEnabledEvent, "blockId", blockIDStr)
}

// UnsetAcrRewardEnabled disables ACR reward for a block (Admin only)
func UnsetAcrRewardEnabled(cur realm, blockID uint32) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	blockIDStr := blockIDToString(blockID)
	blockStore.UnsetAcrRewardEnabled(blockID)

	chain.Emit(UnsetAcrRewardEnabledEvent, "blockId", blockIDStr)
}

// IsAcrRewardEnabled returns true if ACR reward is enabled for the block
func IsAcrRewardEnabled(blockID uint32) bool {
	assertMigrationStateAvailable()
	return blockStore.IsAcrRewardEnabled(blockID)
}

// ListAcrRewardEnabled returns all block IDs with ACR reward enabled
func ListAcrRewardEnabled() []string {
	assertMigrationStateAvailable()
	return blockStore.ListAcrRewardEnabled()
}
