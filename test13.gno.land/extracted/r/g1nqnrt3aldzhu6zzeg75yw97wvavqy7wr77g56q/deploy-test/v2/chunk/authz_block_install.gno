package chunk

import "gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/grc721"

const (
	BlockInstallPermission   = "block:install"
	BlockUninstallPermission = "block:uninstall"
)

// HasInstallPermission checks if caller can install blocks in the chunk.
func HasInstallPermission(tokenID grc721.TokenID, caller address) bool {
	worldID, _, _ := parseChunkKey(tokenID.String())
	return HasWorldPermission(worldID, caller, BlockInstallPermission) ||
		HasChunkPermission(tokenID, caller, BlockInstallPermission)
}

// HasUninstallPermission checks if caller can uninstall blocks from the chunk.
func HasUninstallPermission(tokenID grc721.TokenID, caller address) bool {
	worldID, _, _ := parseChunkKey(tokenID.String())
	return HasWorldPermission(worldID, caller, BlockUninstallPermission) ||
		HasChunkPermission(tokenID, caller, BlockUninstallPermission)
}
