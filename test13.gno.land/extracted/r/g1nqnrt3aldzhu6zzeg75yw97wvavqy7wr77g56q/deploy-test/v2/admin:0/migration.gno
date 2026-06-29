package admin

import "gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/accesscontrol"

var (
	migrationExportCompleted bool
	migrationStateCleaned    bool
)

type MigrationState struct {
	Admin              address
	PendingAdmin       address
	ExplorerURL        string
	FeeCollector       address
	Protocol           address
	Frozen             bool
	FaucetTargetAmount int64
	Operators          []address
}

func GetMigrationState() MigrationState {
	assertMigrationStateAvailable()
	return MigrationState{
		Admin:              admin,
		PendingAdmin:       pendingAdmin,
		ExplorerURL:        explorerURL,
		FeeCollector:       feeCollectorAddr,
		Protocol:           protocolAddr,
		Frozen:             frozen,
		FaucetTargetAmount: faucetTargetAmount,
		Operators:          GetOperators(),
	}
}

func SetMigrationExportCompleted(cur realm, completed bool) {
	accesscontrol.AssertIsAdmin(0, cur, IsAdmin)
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

	operatorAddrs = nil
	faucetTargetAmount = 0
	migrationStateCleaned = true
}

func assertMigrationStateAvailable() {
	if migrationStateCleaned {
		panic("migration state cleaned")
	}
}

func assertCanCleanupMigrationState(_ int, rlm realm) {
	accesscontrol.AssertIsAdmin(0, rlm, IsAdmin)
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
