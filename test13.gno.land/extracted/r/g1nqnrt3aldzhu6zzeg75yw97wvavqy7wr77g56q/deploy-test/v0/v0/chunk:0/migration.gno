package chunk

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/rbac"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/validate"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

type MigrationConfig struct {
	ListLimit        int
	BatchLimit       int
	Frozen           bool
	TokenCount       int64
	WorldCount       int
	MetadataWorlds   int
	OwnerWorlds      int
	VerifierWorlds   int
	PermissionCount  int
	RoleCount        int
	GrantableCount   int
	AuthzGrantCount  int
	WorldMasterCount int
}

func GetMigrationConfig() MigrationConfig {
	assertMigrationStateAvailable()
	return MigrationConfig{
		ListLimit:        listLimit,
		BatchLimit:       batchLimit,
		Frozen:           frozen,
		TokenCount:       nftStore.TokenCount(),
		WorldCount:       worldStore.Total(),
		MetadataWorlds:   nftStore.MetadataWorldSize(),
		OwnerWorlds:      nftStore.OwnerWorldSize(),
		VerifierWorlds:   verifierStore.Verifiers().Size(),
		PermissionCount:  chunkAuthzRBAC.PermissionSize(),
		RoleCount:        chunkAuthzRBAC.RoleSize(),
		GrantableCount:   chunkAuthzRBAC.GrantSize(),
		AuthzGrantCount:  chunkAuthzRBAC.AssignmentSize(),
		WorldMasterCount: worldAuthzRBAC.AssignmentSize(),
	}
}

func GetMigrationWorldStore(cur realm) *WorldStore {
	assertCanExposeMigrationStore(0, cur)
	return worldStore
}

func GetMigrationWorldCreateValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return worldCreateValidator
}

func GetMigrationWorldUpdateValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return worldUpdateValidator
}

func GetMigrationNFTStore(cur realm) *NFTStore {
	assertCanExposeMigrationStore(0, cur)
	return nftStore
}

func GetMigrationVerifierStore(cur realm) *VerifierStore {
	assertCanExposeMigrationStore(0, cur)
	return verifierStore
}

func GetMigrationChunkAuthzRBAC(cur realm) *rbac.RBAC {
	assertCanExposeMigrationStore(0, cur)
	return chunkAuthzRBAC
}

func GetMigrationWorldAuthzRBAC(cur realm) *rbac.RBAC {
	assertCanExposeMigrationStore(0, cur)
	return worldAuthzRBAC
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

	worldStore = nil
	nftStore = nil
	verifierStore = nil
	chunkAuthzRBAC = nil
	worldAuthzRBAC = nil

	migrationStateCleaned = true
}

func assertCanExposeMigrationStore(_ int, rlm realm) {
	accesscontrol.AssertCurrentRealm(0, rlm)
	accesscontrol.AssertIsAdminOrigin(admin.IsAdmin)
	assertMigrationMigratorConfigured()
	assertMigrationMigratorCodeRealm(0, rlm)
	assertMigrationMigratorRealm(0, rlm)
	assertCanExposeMigrationChunkStore()
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

func assertCanExposeMigrationChunkStore() {
	assertMigrationStateAvailable()
	if !frozen {
		panic("contract must be frozen")
	}
	if migrationCompleted {
		panic("migration already completed")
	}
}
