package acr

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

type MigrationConfig struct {
	ListLimit             int
	Frozen                bool
	TotalSupply           int64
	KnownAccounts         int
	BalanceIndexCount     int
	MintIndexCount        int
	UserMintTotalCount    int
	ProcessedRequestCount int
	HofCategoryCount      int
}

func GetMigrationConfig() MigrationConfig {
	assertMigrationStateAvailable()
	return MigrationConfig{
		ListLimit:             listLimit,
		Frozen:                frozen,
		TotalSupply:           acrStore.TotalSupply(),
		KnownAccounts:         acrStore.Token().KnownAccounts(),
		BalanceIndexCount:     acrStore.BalanceIndexCount(),
		MintIndexCount:        acrStore.MintIndexCount(),
		UserMintTotalCount:    acrStore.UserMintTotalCount(),
		ProcessedRequestCount: acrStore.ProcessedRequestCount(),
		HofCategoryCount:      acrStore.HofCategoryCount(),
	}
}

func GetMigrationACRStore(cur realm) *ACRStore {
	assertCanExposeMigrationStore(0, cur)
	return acrStore
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
	// Clearing is intentionally allowed after migration cleanup so the source realm
	// can remove the temporary authorized migrator pointer as the final operation.
	migrationMigratorPkgPath = ""
}

func SetMigrationCompleted(cur realm, completed bool) {
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	assertMigrationStateAvailable()
	migrationCompleted = completed
}

func IsMigrationCompleted() bool {
	return migrationCompleted
}

func IsMigrationStateCleaned() bool {
	return migrationStateCleaned
}

func CleanupMigrationState(cur realm) {
	assertCanCleanupMigrationState(0, cur)

	acrStore = nil

	migrationStateCleaned = true
}

func assertCanExposeMigrationStore(_ int, rlm realm) {
	accesscontrol.AssertCurrentRealm(0, rlm)
	accesscontrol.AssertIsAdminOrigin(admin.IsAdmin)
	assertMigrationMigratorConfigured()
	assertMigrationMigratorCodeRealm(0, rlm)
	assertMigrationMigratorRealm(0, rlm)
	assertCanExposeMigrationACRStore()
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
	if !migrationCompleted {
		panic("migration not completed")
	}
	if migrationStateCleaned {
		panic("migration state already cleaned")
	}
}

func assertCanExposeMigrationACRStore() {
	assertMigrationStateAvailable()
	if !frozen {
		panic("contract must be frozen")
	}
	if migrationCompleted {
		panic("migration already completed")
	}
}
