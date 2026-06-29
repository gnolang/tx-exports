package personal_world

import (
	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/p/akkadia/v0/rbac"
	"gno.land/p/akkadia/v0/validate"
	"gno.land/r/akkadia/v0/admin"
)

var (
	migrationMigratorPkgPath string
	migrationExportCompleted bool
	migrationStateCleaned    bool
)

type MigrationConfig struct {
	FeeCollectorBPS int
	ListLimit       int
	BatchLimit      int
	Frozen          bool
	NextWorldID     uint32
	TotalWorlds     int
	TotalBiomes     int
	TotalSizes      int
}

func GetMigrationConfig() MigrationConfig {
	assertMigrationStateAvailable()
	worlds := worldStore
	return MigrationConfig{
		FeeCollectorBPS: feeCollectorBPS,
		ListLimit:       listLimit,
		BatchLimit:      batchLimit,
		Frozen:          frozen,
		NextWorldID:     worlds.NextID(),
		TotalWorlds:     worlds.Total(),
		TotalBiomes:     worldConfigStore.TotalBiomes(),
		TotalSizes:      worldConfigStore.TotalSizes(),
	}
}

func GetMigrationWorldStore(cur realm) *WorldStore {
	assertCanExposeMigrationStore(0, cur)
	return worldStore
}

func GetMigrationWorldConfigStore(cur realm) *WorldConfigStore {
	assertCanExposeMigrationStore(0, cur)
	return worldConfigStore
}

func GetMigrationVerifierStore(cur realm) *VerifierStore {
	assertCanExposeMigrationStore(0, cur)
	return verifierStore
}

func GetMigrationPersonalWorldAuthzRBAC(cur realm) *rbac.RBAC {
	assertCanExposeMigrationStore(0, cur)
	return personalWorldAuthzRBAC
}

func GetMigrationWorldCreateValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return worldCreateValidator
}

func GetMigrationWorldUpdateValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return worldUpdateValidator
}

func GetMigrationSizeInfoValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return sizeInfoValidator
}

func GetMigrationBiomeInfoValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return biomeInfoValidator
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

	personalWorldAuthzRBAC = nil
	worldStore = nil
	worldConfigStore = nil
	verifierStore = nil
	worldCreateValidator = nil
	worldUpdateValidator = nil
	sizeInfoValidator = nil
	biomeInfoValidator = nil

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
