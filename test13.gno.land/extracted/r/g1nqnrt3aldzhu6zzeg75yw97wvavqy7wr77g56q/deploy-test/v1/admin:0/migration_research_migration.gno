package admin

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/accesscontrol"
	oldadmin "gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

var (
	migrationInitialized bool
	migrationFinalized   bool
)

// MigrationInit is the only state-changing admin migration call.
func MigrationInit(cur realm) {
	accesscontrol.AssertIsAdmin(0, cur, oldadmin.IsAdmin)
	if migrationInitialized {
		panic("migration already initialized")
	}
	if migrationFinalized {
		panic("migration already finalized")
	}

	state := oldadmin.GetMigrationState()
	admin = state.Admin
	pendingAdmin = state.PendingAdmin
	explorerURL = state.ExplorerURL
	feeCollectorAddr = state.FeeCollector
	protocolAddr = state.Protocol
	frozen = state.Frozen
	faucetTargetAmount = state.FaucetTargetAmount

	operatorAddrs = make(map[address]bool)
	for _, operator := range state.Operators {
		operatorAddrs[operator] = true
	}

	migrationInitialized = true
	migrationFinalized = true
}

// IsMigrationInitialized reports whether MigrationInit has copied the admin state.
func IsMigrationInitialized() bool {
	return migrationInitialized
}

// IsMigrationFinalized reports whether the one-shot admin migration is complete.
func IsMigrationFinalized() bool {
	return migrationFinalized
}
