package acr

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	oldacr "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/acr"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v1/admin"
)

const (
	migrationPhaseFinalized = iota
)

var (
	migrationInitialized      bool
	migrationFinalized        bool
	migrationGRC20Initialized bool
	migrationPhase            int
	migrationOffset           int
)

// MigrationInit is the first next-package call made by the research driver.
func MigrationInit(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	if migrationInitialized {
		panic("migration already initialized")
	}

	config := oldacr.GetMigrationConfig()
	listLimit = config.ListLimit
	frozen = config.Frozen
	acrStore = oldacr.GetMigrationACRStore(cross(cur))
	migrationGRC20Initialized = true

	migrationInitialized = true
	migrationFinalized = true
	migrationPhase = migrationPhaseFinalized
	migrationOffset = 0
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

// IsGRC20MigrationInitialized reports whether the token store pointer is attached.
func IsGRC20MigrationInitialized() bool {
	return migrationGRC20Initialized
}

func resetMigrationState() {
	migrationInitialized = false
	migrationFinalized = false
	migrationGRC20Initialized = false
	migrationPhase = migrationPhaseFinalized
	migrationOffset = 0
}
