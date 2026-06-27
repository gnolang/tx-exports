package chunk

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	oldchunk "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/chunk"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v1/admin"
)

const (
	migrationPhaseWorlds = iota
	migrationPhaseMetadata
	migrationPhaseVerifiers
	migrationPhaseOwners
	migrationPhaseAuthzDefinitions
	migrationPhaseAuthzGrants
	migrationPhaseWorldMasters
	migrationPhaseFinalized
)

var (
	migrationInitialized       bool
	migrationFinalized         bool
	migrationGRC721Initialized bool
	migrationPhase             int
	migrationOffset            int
)

// MigrationInit is the first next-package call made by the research driver.
func MigrationInit(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	if migrationInitialized {
		panic("migration already initialized")
	}

	config := oldchunk.GetMigrationConfig()
	resetMigrationDestination(cur, config)

	migrationInitialized = true
	migrationFinalized = true
	migrationPhase = migrationPhaseFinalized
	migrationOffset = int(config.TokenCount)
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

// IsGRC721MigrationInitialized reports whether the NFT store pointer is attached.
func IsGRC721MigrationInitialized() bool {
	return migrationGRC721Initialized
}

func resetMigrationState() {
	migrationInitialized = false
	migrationFinalized = false
	migrationGRC721Initialized = false
	migrationPhase = migrationPhaseWorlds
	migrationOffset = 0
}

func resetMigrationDestination(cur realm, config oldchunk.MigrationConfig) {
	listLimit = config.ListLimit
	batchLimit = config.BatchLimit
	frozen = config.Frozen

	worldStore = oldchunk.GetMigrationWorldStore(cross(cur))
	nftStore = oldchunk.GetMigrationNFTStore(cross(cur))
	verifierStore = oldchunk.GetMigrationVerifierStore(cross(cur))
	migrationGRC721Initialized = true

	chunkAuthzRBAC = oldchunk.GetMigrationChunkAuthzRBAC(cross(cur))
	worldAuthzRBAC = oldchunk.GetMigrationWorldAuthzRBAC(cross(cur))
}
