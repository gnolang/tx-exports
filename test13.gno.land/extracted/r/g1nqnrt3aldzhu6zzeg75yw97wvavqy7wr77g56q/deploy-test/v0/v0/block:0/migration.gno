package block

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/validate"
	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

type MigrationConfig struct {
	NextBlockID           uint32
	SystemBlockLimit      uint32
	MaxSystemBlockID      uint32
	NextLogID             uint64
	CreatorBPS            int
	ListLimit             int
	Frozen                bool
	BlockCount            int
	BlockNameIndexCount   int
	SupplyCount           int
	UserInventoryCount    int
	MintAllowlistCount    int
	AcrRewardCount        int
	PersonalInstalledSize int
	SystemInstalledSize   int
	UseLogCount           int
	UserLogIndexCount     int
}

func GetMigrationConfig() MigrationConfig {
	assertMigrationStateAvailable()
	return MigrationConfig{
		NextBlockID:           blockStore.NextID(),
		SystemBlockLimit:      blockStore.SystemBlockLimit(),
		MaxSystemBlockID:      blockStore.MaxSystemBlockID(),
		NextLogID:             installedBlockStore.NextLogID(),
		CreatorBPS:            creatorBPS,
		ListLimit:             listLimit,
		Frozen:                frozen,
		BlockCount:            blockStore.Total(),
		BlockNameIndexCount:   blockStore.NameIndexTotal(),
		SupplyCount:           mintedBlockStore.SupplyTotal(),
		UserInventoryCount:    mintedBlockStore.UserInventoryTotal(),
		MintAllowlistCount:    mintedBlockStore.MintAllowlistTotal(),
		AcrRewardCount:        blockStore.AcrRewardTotal(),
		PersonalInstalledSize: installedBlockStore.PersonalInstalledTotal(),
		SystemInstalledSize:   installedBlockStore.SystemInstalledTotal(),
		UseLogCount:           installedBlockStore.UseLogTotal(),
		UserLogIndexCount:     installedBlockStore.UserLogIndexTotal(),
	}
}

func GetMigrationBlockStore(cur realm) *BlockStore {
	assertCanExposeMigrationStore(0, cur)
	return blockStore
}

func GetMigrationInstalledBlockStore(cur realm) *InstalledBlockStore {
	assertCanExposeMigrationStore(0, cur)
	return installedBlockStore
}

func GetMigrationMintedBlockStore(cur realm) *MintedBlockStore {
	assertCanExposeMigrationStore(0, cur)
	return mintedBlockStore
}

func GetMigrationCreateValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return createValidator
}

func GetMigrationUpdateValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return updateValidator
}

func GetMigrationInstallValidator(cur realm) *validate.Validator {
	assertCanExposeMigrationStore(0, cur)
	return installValidator
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

	blockStore = nil
	installedBlockStore = nil
	mintedBlockStore = nil
	createValidator = nil
	updateValidator = nil
	installValidator = nil

	migrationStateCleaned = true
}

func assertCanExposeMigrationStore(_ int, rlm realm) {
	accesscontrol.AssertCurrentRealm(0, rlm)
	accesscontrol.AssertIsAdminOrigin(admin.IsAdmin)
	assertMigrationMigratorConfigured()
	assertMigrationMigratorCodeRealm(0, rlm)
	assertMigrationMigratorRealm(0, rlm)
	assertCanExposeMigrationStoreAvailable()
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

func assertCanExposeMigrationStoreAvailable() {
	assertMigrationStateAvailable()
	if !frozen {
		panic("contract must be frozen")
	}
	if migrationCompleted {
		panic("migration already completed")
	}
}
