package blueprint

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
	CreationCost    int64
	ListLimit       int
	BatchLimit      int
	Frozen          bool
	NextBlueprintID uint32
	TotalBlueprints int
	TotalVerifiers  int
}

func GetMigrationConfig() MigrationConfig {
	assertMigrationStateAvailable()
	return MigrationConfig{
		CreationCost:    creationCost,
		ListLimit:       listLimit,
		BatchLimit:      batchLimit,
		Frozen:          frozen,
		NextBlueprintID: blueprintStore.NextID(),
		TotalBlueprints: blueprintStore.Total(),
		TotalVerifiers:  verifierStore.Total(),
	}
}

func GetMigrationBlueprintStore(cur realm) *BlueprintStore {
	assertCanExposeMigrationStore(0, cur)
	return blueprintStore
}

func GetMigrationVerifierStore(cur realm) *VerifierStore {
	assertCanExposeMigrationStore(0, cur)
	return verifierStore
}

func GetMigrationBlueprintCreateValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return blueprintCreateValidator
}

func GetMigrationBlueprintUpdateValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return blueprintUpdateValidator
}

func SetMigrationMigrator(cur realm, pkgPath string) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertMigrationStateAvailable()
	if pkgPath == "" {
		panic("migration migrator is required")
	}
	migrationMigratorPkgPath = pkgPath
}

func ClearMigrationMigrator(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertMigrationStateAvailable()
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

	blueprintStore = nil
	verifierStore = nil
	blueprintCreateValidator = nil
	blueprintUpdateValidator = nil

	migrationStateCleaned = true
}

func assertCanExposeMigrationStore(_ int, rlm realm) {
	accesscontrol.AssertCurrentRealm(0, rlm)
	accesscontrol.AssertIsAdminOrigin(admin.IsAdmin)
	assertMigrationMigratorConfigured()
	assertMigrationMigratorCodeRealm(0, rlm)
	assertMigrationMigratorRealm(0, rlm)
	assertCanExposeMigrationStores()
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

func assertCanExposeMigrationStores() {
	assertMigrationStateAvailable()
	if !frozen {
		panic("contract must be frozen")
	}
	if migrationExportCompleted {
		panic("migration already completed")
	}
}
