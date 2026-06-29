package user

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/validate"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/admin"
)

var (
	migrationMigratorPkgPath string
	migrationExportCompleted bool
	migrationStateCleaned    bool
)

type MigrationConfig struct {
	ListLimit  int
	Frozen     bool
	TotalUsers int
	NextUserID uint32
}

func GetMigrationConfig() MigrationConfig {
	assertMigrationStateAvailable()
	return MigrationConfig{
		ListLimit:  listLimit,
		Frozen:     frozen,
		TotalUsers: userStore.Total(),
		NextUserID: userStore.NextID(),
	}
}

func GetMigrationUserStore(cur realm) *UserStore {
	assertCanExposeMigrationStore(0, cur)
	return userStore
}

func GetMigrationCreateValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return createValidator
}

func GetMigrationUpdateValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return updateValidator
}

func SetMigrationMigrator(cur realm, pkgPath string) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	if pkgPath == "" {
		panic("migration migrator is required")
	}
	migrationMigratorPkgPath = pkgPath
}

func ClearMigrationMigrator(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	migrationMigratorPkgPath = ""
}

func SetMigrationExportCompleted(cur realm, completed bool) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertMigrationStateAvailable()
	migrationExportCompleted = completed
}

func IsMigrationExportCompleted() bool {
	return migrationExportCompleted
}

func IsMigrationStateCleaned() bool {
	return migrationStateCleaned
}

func CleanupMigrationState(cur realm) {
	assertCanCleanupMigrationState(0, cur)

	userStore = nil
	createValidator = nil
	updateValidator = nil

	migrationStateCleaned = true
}

func assertCanExposeMigrationStore(_ int, rlm realm) {
	accesscontrol.AssertCurrentRealm(0, rlm)
	accesscontrol.AssertIsAdminOrigin(admin.IsAdmin)
	assertMigrationMigratorConfigured()
	assertMigrationMigratorCodeRealm(0, rlm)
	assertMigrationMigratorRealm(0, rlm)
	assertCanExposeMigrationUserStore()
}

func assertMigrationMigratorConfigured() {
	if migrationMigratorPkgPath == "" {
		panic("migration migrator not set")
	}
}

func assertMigrationMigratorCodeRealm(_ int, rlm realm) {
	if rlm.Previous().PkgPath() == "" {
		panic("migration migrator must be code realm")
	}
}

func assertMigrationMigratorRealm(_ int, rlm realm) {
	if rlm.Previous().PkgPath() != migrationMigratorPkgPath {
		panic("migration migrator access required")
	}
}

func assertMigrationStateAvailable() {
	if migrationStateCleaned {
		panic("migration state cleaned")
	}
}

func assertCanCleanupMigrationState(_ int, rlm realm) {
	accesscontrol.AssertIsAdmin(0, rlm, admin.IsAdmin)
	if !frozen {
		panic("contract must be frozen")
	}
	if !migrationExportCompleted {
		panic("migration not completed")
	}
	if migrationStateCleaned {
		panic("migration state already cleaned")
	}
}

func assertCanExposeMigrationUserStore() {
	assertMigrationStateAvailable()
	if !frozen {
		panic("contract must be frozen")
	}
	if migrationExportCompleted {
		panic("migration already completed")
	}
}
