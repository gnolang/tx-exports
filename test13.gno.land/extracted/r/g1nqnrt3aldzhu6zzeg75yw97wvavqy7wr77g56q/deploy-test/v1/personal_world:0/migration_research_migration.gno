package personal_world

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	oldpw "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/personal_world"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v1/admin"
)

var (
	migrationInitialized bool
	migrationFinalized   bool
	migrationOffset      int
	migrationTotal       int
	migrationLastWorldID uint32
)

// MigrationInit is the first next-package call made by the research driver.
func MigrationInit(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	if migrationInitialized {
		panic("migration already initialized")
	}

	config := oldpw.GetMigrationConfig()
	resetMigrationDestination(cur, config)

	migrationInitialized = true
	migrationOffset = migrationTotal
	migrationFinalized = true
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

	migrationOffset = migrationTotal
	migrationFinalized = true
}

// IsMigrationInitialized reports whether MigrationInit has run.
func IsMigrationInitialized() bool {
	return migrationInitialized
}

// IsMigrationFinalized reports whether migration batches are complete.
func IsMigrationFinalized() bool {
	return migrationFinalized
}

// GetMigrationOffset reports the number of source records accounted for by migration.
func GetMigrationOffset() int {
	return migrationOffset
}

// GetMigrationTotal reports the source world total captured during MigrationInit.
func GetMigrationTotal() int {
	return migrationTotal
}

// GetMigrationLastWorldID reports the cursor world ID used by batch migration.
func GetMigrationLastWorldID() uint32 {
	return migrationLastWorldID
}

func resetMigrationDestination(cur realm, config oldpw.MigrationConfig) {
	feeCollectorBPS = config.FeeCollectorBPS
	listLimit = config.ListLimit
	batchLimit = config.BatchLimit
	frozen = config.Frozen
	worldStore = oldpw.GetMigrationWorldStore(cross(cur))
	worldConfigStore = oldpw.GetMigrationWorldConfigStore(cross(cur))
	verifierStore = oldpw.GetMigrationVerifierStore(cross(cur))
	personalWorldAuthzRBAC = oldpw.GetMigrationPersonalWorldAuthzRBAC(cross(cur))

	migrationOffset = 0
	migrationTotal = config.TotalWorlds
	migrationLastWorldID = 0
}
