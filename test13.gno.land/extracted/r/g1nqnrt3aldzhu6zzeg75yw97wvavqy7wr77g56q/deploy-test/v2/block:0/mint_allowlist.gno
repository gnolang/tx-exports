package block

import (
	"chain"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
)

const (
	SetMintAllowlistEvent    = "SetMintAllowlist"
	RemoveMintAllowlistEvent = "RemoveMintAllowlist"
)

// SetMintAllowlist adds minters (comma-separated) to the allowlist for a block.
// Each address is trimmed of whitespace and validated before storage.
// Adds to existing allowlist; creates a new one if none exists.
// Admin only.
func SetMintAllowlist(cur realm, blockID uint32, minters string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	blockIDStr := blockIDToString(blockID)
	if !blockStore.Has(blockID) {
		panic("block not found: " + blockIDStr)
	}
	mintedBlockStore.SetMintAllowlist(blockID, parseMintAllowlistCSV(minters))

	chain.Emit(SetMintAllowlistEvent,
		"blockId", blockIDStr,
		"minters", minters,
	)
}

// RemoveMintAllowlist removes minters (comma-separated) from the allowlist for a block.
// Each address is trimmed of whitespace and validated before lookup.
// If the allowlist becomes empty, removes the block entry (= no restriction).
// Admin only.
func RemoveMintAllowlist(cur realm, blockID uint32, minters string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	blockIDStr := blockIDToString(blockID)
	mintedBlockStore.RemoveMintAllowlist(blockID, parseMintAllowlistCSV(minters))

	chain.Emit(RemoveMintAllowlistEvent,
		"blockId", blockIDStr,
		"minters", minters,
	)
}

// GetMintAllowlist returns the list of allowed minter addresses.
// Returns empty slice if no restriction is set.
func GetMintAllowlist(blockID uint32) []string {
	assertMigrationStateAvailable()
	return mintedBlockStore.GetMintAllowlist(blockID)
}
