package user

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	oldadmin "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
	olduser "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/user"
)

var (
	migrationInitialized  bool
	migrationFinalized    bool
	migrationOffset       int
	migrationTotal        int
	migrationLastAddress  string
	migrationLastNickname string
)

// MigrationInit is the first next-package call made by the research driver.
func MigrationInit(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, oldadmin.IsAdmin)
	if migrationInitialized {
		panic("migration already initialized")
	}

	initializeMigration(cur)
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

	assertMigrationCursor()

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

// GetMigrationTotal reports the source record total captured during MigrationInit.
func GetMigrationTotal() int {
	return migrationTotal
}

// GetMigrationLastNickname reports the cursor nickname used by batch migration.
func GetMigrationLastNickname() string {
	return migrationLastNickname
}

func initializeMigration(cur realm) {
	if migrationInitialized {
		return
	}

	config := olduser.GetMigrationConfig()
	listLimit = config.ListLimit
	userStore = olduser.GetMigrationUserStore(cross(cur))
	migrationTotal = config.TotalUsers
	migrationOffset = 0

	migrationInitialized = true
}

func assertMigrationCursor() {
	if migrationOffset == 0 {
		return
	}
	if migrationLastAddress == "" || migrationLastNickname == "" {
		panic("invalid migration cursor")
	}
	if GetNickname(address(migrationLastAddress)) != migrationLastNickname {
		panic("migration cursor mismatch")
	}
	if GetAddressByNickname(migrationLastNickname).String() != migrationLastAddress {
		panic("migration cursor mismatch")
	}
}
