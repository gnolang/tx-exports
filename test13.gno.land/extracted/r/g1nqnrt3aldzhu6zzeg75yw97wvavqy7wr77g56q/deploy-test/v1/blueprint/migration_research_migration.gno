package blueprint

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	oldadmin "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
	oldbp "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/blueprint"
)

var (
	migrationInitialized bool
	migrationFinalized   bool
	migrationOffset      int
	migrationTotal       int
)

// MigrationInit is the first next-package call made by the research driver.
func MigrationInit(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, oldadmin.IsAdmin)
	if migrationInitialized {
		panic("migration already initialized")
	}

	config := oldbp.GetMigrationConfig()
	resetMigrationDestination(cur, config)

	migrationInitialized = true
	migrationOffset = migrationTotal
	migrationFinalized = true
}

// MigrationNext advances the migration after MigrationInit until finalization.
func MigrationNext(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, oldadmin.IsAdmin)
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

// GetMigrationTotal reports the source blueprint total captured during MigrationInit.
func GetMigrationTotal() int {
	return migrationTotal
}

func resetMigrationDestination(cur realm, config oldbp.MigrationConfig) {
	creationCost = config.CreationCost
	listLimit = config.ListLimit
	batchLimit = config.BatchLimit
	frozen = config.Frozen
	blueprintStore = oldbp.GetMigrationBlueprintStore(cross(cur))
	verifierStore = oldbp.GetMigrationVerifierStore(cross(cur))
	blueprintCreateValidator = oldbp.GetMigrationBlueprintCreateValidator(cross(cur))
	blueprintUpdateValidator = oldbp.GetMigrationBlueprintUpdateValidator(cross(cur))

	migrationOffset = 0
	migrationTotal = config.TotalBlueprints
}
