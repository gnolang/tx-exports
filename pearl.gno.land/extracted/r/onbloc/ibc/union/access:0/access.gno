package access

import "gno.land/p/onbloc/access/manager"

var accessState manager.State

// RelayerRole mirrors Union deployer's RELAYER role id.
// Reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/deployer/src/main.rs#L65
const RelayerRole manager.RoleId = 1

// GrantRole grants role membership to account through the shared access realm.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L69-L87
func GrantRole(cur realm, role manager.RoleId, account address) bool {
	assertCanAdminRole(0, cur, role)

	newMember := accessState.GrantRole(role, account)
	since := accessState.GetRoleMemberSince(role, account)

	emitRoleGrantedEvent(role, account, since, newMember)

	return newMember
}

// RevokeRole revokes role membership from account through the shared access realm.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L89-L100
func RevokeRole(cur realm, role manager.RoleId, account address) bool {
	assertCanAdminRole(0, cur, role)

	revoked := accessState.RevokeRole(role, account)
	if revoked {
		emitRoleRevokedEvent(role, account)
	}

	return revoked
}

// RenounceRole revokes the caller's own role membership after confirmation.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L102-L115
func RenounceRole(cur realm, role manager.RoleId, callerConfirmation address) bool {
	account := cur.Previous().Address()

	revoked := accessState.RenounceRole(role, account, callerConfirmation)
	if revoked {
		emitRoleRevokedEvent(role, account)
	}

	return revoked
}

// LabelRole emits role label metadata for an unlocked role.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L48-L67
func LabelRole(cur realm, role manager.RoleId, label string) {
	assertCanManageTarget(0, cur)

	manager.RequireUnlockedConfigRole(role)

	emitRoleLabelEvent(role, label)
}

// SetRoleAdmin sets the admin role that can grant or revoke role.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L117-L126
func SetRoleAdmin(cur realm, role manager.RoleId, admin manager.RoleId) {
	assertCanManageTarget(0, cur)

	accessState.SetRoleAdmin(role, admin)

	emitRoleAdminChangedEvent(role, admin)
}

// SetGrantDelay schedules delay behind a setback (manager.State.SetGrantDelay).
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L139-L148
func SetGrantDelay(cur realm, role manager.RoleId, newDelay uint32) {
	assertCanManageTarget(0, cur)

	accessState.SetGrantDelay(role, newDelay)
	effect := accessState.GetRoleGrantDelayEffect(role)

	emitRoleGrantDelayChangedEvent(role, newDelay, effect)
}

// SetFunctionRole sets the role for selector on targetPath.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L353-L367
func SetFunctionRole(cur realm, targetPath string, selector manager.Selector, role manager.RoleId) {
	assertCanManageTarget(0, cur)

	accessState.SetTargetFunctionRole(targetPath, selector, role)

	emitTargetFunctionRoleUpdatedEvent(targetPath, selector, role)
}

// SetFunctionRoles sets the same role for selectors on targetPath.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L353-L367
func SetFunctionRoles(cur realm, targetPath string, selectors []manager.Selector, role manager.RoleId) {
	assertCanManageTarget(0, cur)

	accessState.SetTargetFunctionRoles(targetPath, selectors, role)

	for i := range selectors {
		emitTargetFunctionRoleUpdatedEvent(targetPath, selectors[i], role)
	}
}

// SetTargetClosed sets whether targetPath is closed.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L450-L483
func SetTargetClosed(cur realm, targetPath string, closed bool) {
	assertCanManageTarget(0, cur)

	accessState.SetTargetClosed(targetPath, closed)

	emitTargetClosedEvent(targetPath, closed)
}
