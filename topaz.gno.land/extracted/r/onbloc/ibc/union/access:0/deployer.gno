package access

import (
	"gno.land/p/onbloc/access/manager"
	"gno.land/p/onbloc/ibc/union/types"
)

const (
	CoreRealmPath       = "gno.land/r/onbloc/ibc/union/core"
	DefaultAdminAddress = address("g1qgr7980ry7f6rqr9cs6d45y09k5u6dzhjksksn")
)

func init() {
	resetAccess(DefaultAdminAddress)
}

// resetAccess mirrors the deploy-time setup that Union performs through its
// deployer after instantiating AccessManager. Gno has no instantiate message, so
// this realm uses DefaultAdminAddress as its initial admin during init.
func resetAccess(initialAdmin address) {
	accessState = manager.NewState()

	// Mirrors initial admin bootstrap only:
	// OZ AccessManager constructor:
	// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.6.1/contracts/access/manager/AccessManager.sol#L133-L136
	// Union access-manager init:
	// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/lib.rs#L148-L154
	//
	// RELAYER membership is separate deployer policy in Union and is granted by
	// GrantRole, not by AccessManager initialization:
	// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/deployer/src/main.rs#L1143-L1152
	accessState.GrantRole(manager.AdminRole, initialAdmin)
	access := accessState.Roles[manager.AdminRole].Members[initialAdmin]
	emitRoleGrantedEvent(manager.AdminRole, initialAdmin, access.Since, true)
	setupRoles()
}

// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/deployer/src/main.rs#L1779
func setupRoles() {
	accessState.SetTargetFunctionRoles(CoreRealmPath, types.RelayerSelectors(), RelayerRole)
	for _, selector := range types.RelayerSelectors() {
		emitTargetFunctionRoleUpdatedEvent(CoreRealmPath, selector, RelayerRole)
	}
	// Union deployer labels all production roles. We only bootstrap RELAYER for
	// now; PAUSER/UNPAUSER/RATE_LIMITER are added when their roles are adopted.
	// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/deployer/src/main.rs#L1871-L1908
	manager.RequireUnlockedConfigRole(RelayerRole)
	emitRoleLabelEvent(RelayerRole, "RELAYER")
}
