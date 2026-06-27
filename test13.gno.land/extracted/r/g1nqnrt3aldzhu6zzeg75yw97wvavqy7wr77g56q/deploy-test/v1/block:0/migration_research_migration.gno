package block

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	oldblock "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/block"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v1/admin"
)

const (
	migrationPhaseBlocks = iota
	migrationPhaseSupply
	migrationPhaseUserInventory
	migrationPhaseMintAllowlist
	migrationPhasePersonalInstalled
	migrationPhaseSystemInstalled
	migrationPhaseUseLogs
	migrationPhaseUserLogIndex
	migrationPhaseFinalized
)

var (
	migrationInitialized bool
	migrationFinalized   bool
	migrationPhase       int
	migrationOffset      int
)

// MigrationInit is the first next-package call made by the research driver.
func MigrationInit(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	if migrationInitialized {
		panic("migration already initialized")
	}

	config := oldblock.GetMigrationConfig()
	resetMigrationDestination(cur, config)

	migrationInitialized = true
	migrationFinalized = true
	migrationPhase = migrationPhaseFinalized
	migrationOffset = config.BlockCount
}

// MigrationNext advances the migration after MigrationInit until finalization.
func MigrationNext(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	if !migrationInitialized {
		panic("migration not initialized")
	}
	if migrationFinalized {
		panic("migration already finalized")
	}

	migrationFinalized = true
	migrationPhase = migrationPhaseFinalized
}

// IsMigrationInitialized reports whether MigrationInit has run.
func IsMigrationInitialized() bool {
	return migrationInitialized
}

// IsMigrationFinalized reports whether migration batches are complete.
func IsMigrationFinalized() bool {
	return migrationFinalized
}

// GetMigrationPhase reports the current migration phase.
func GetMigrationPhase() int {
	return migrationPhase
}

// GetMigrationOffset reports the current migration offset within the phase.
func GetMigrationOffset() int {
	return migrationOffset
}

// IsGRC1155MigrationInitialized reports whether the token store pointer is attached.
func IsGRC1155MigrationInitialized() bool {
	return mintedBlockStore != nil && mintedBlockStore.Token() != nil
}

func resetMigrationDestination(cur realm, config oldblock.MigrationConfig) {
	creatorBPS = config.CreatorBPS
	listLimit = config.ListLimit
	frozen = config.Frozen

	blockStore = oldblock.GetMigrationBlockStore(cross(cur))
	installedBlockStore = oldblock.GetMigrationInstalledBlockStore(cross(cur))
	mintedBlockStore = oldblock.GetMigrationMintedBlockStore(cross(cur))
}
