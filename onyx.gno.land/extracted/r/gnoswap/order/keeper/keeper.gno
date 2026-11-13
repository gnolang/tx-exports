package keeper

import (
	"gno.land/p/gnoswap/order/access/manager/v0"
)

// AddRole registers a custom role with label and returns its id.
// Admin or governance only.
func AddRole(cur realm, label string) manager.RoleId {
	assertIsAdminOrGovernance(cur)
	assertIsAvailableLabel(label)

	role := nextCustomRoleId()
	registerRole(role, label)

	return role
}

// SetRoleLabel renames a registered role. Admin or governance only.
func SetRoleLabel(cur realm, role manager.RoleId, label string) {
	assertIsAdminOrGovernance(cur)
	assertIsRegisteredRole(role)
	assertIsAvailableLabel(label)

	roleLabels[role] = label
	emitRoleLabel(role, label)
}

// GrantRole grants role to account and reports whether account is a new
// member. Membership starts after the role's grant delay.
// Admin or governance only.
func GrantRole(cur realm, role manager.RoleId, account address) bool {
	assertIsAdminOrGovernance(cur)
	assertIsRegisteredRole(role)
	assertIsValidAddress(account)

	newMember := accessState.GrantRole(role, account)
	emitRoleGranted(role, account, accessState.GetRoleMemberSince(role, account), newMember)

	return newMember
}

// RevokeRole revokes role from account and reports whether it was a member.
// Admin or governance only.
func RevokeRole(cur realm, role manager.RoleId, account address) bool {
	assertIsAdminOrGovernance(cur)
	assertIsRegisteredRole(role)

	revoked := accessState.RevokeRole(role, account)
	if revoked {
		emitRoleRevoked(role, account)
	}

	return revoked
}

// RenounceRole revokes role from the caller.
// callerConfirmation must be the caller's address.
func RenounceRole(cur realm, role manager.RoleId, callerConfirmation address) bool {
	assertIsRegisteredRole(role)

	account := cur.Previous().Address()

	revoked := accessState.RenounceRole(role, account, callerConfirmation)
	if revoked {
		emitRoleRevoked(role, account)
	}

	return revoked
}

// SetRoleGrantDelay schedules the delay, in seconds, before new members of role
// become active. The change itself waits manager.MinSetback.
// Admin or governance only.
func SetRoleGrantDelay(cur realm, role manager.RoleId, delay uint32) {
	assertIsAdminOrGovernance(cur)
	assertIsRegisteredRole(role)

	accessState.SetGrantDelay(role, delay)
	emitRoleGrantDelayChanged(role, delay, accessState.GetRoleGrantDelayEffect(role))
}

// SetTargetFunctionRole assigns role, or manager.PublicRole for anyone, to
// selector on target (a realm package path). Admin or governance only.
func SetTargetFunctionRole(cur realm, target string, selector manager.Selector, role manager.RoleId) {
	assertIsAdminOrGovernance(cur)
	assertIsValidTarget(target)
	assertIsAssignableRole(role)

	accessState.SetTargetFunctionRole(target, selector, role)
	emitTargetFunctionRoleUpdated(target, selector, role)
}

// SetTargetFunctionRoles assigns role to several selectors on target.
// Admin or governance only.
func SetTargetFunctionRoles(cur realm, target string, selectors []manager.Selector, role manager.RoleId) {
	assertIsAdminOrGovernance(cur)
	assertIsValidTarget(target)
	assertIsAssignableRole(role)

	accessState.SetTargetFunctionRoles(target, selectors, role)

	for _, selector := range selectors {
		emitTargetFunctionRoleUpdated(target, selector, role)
	}
}

// SetTargetClosed closes or reopens target. A closed target rejects every
// call, whatever its selector roles. Admin or governance only.
func SetTargetClosed(cur realm, target string, closed bool) {
	assertIsAdminOrGovernance(cur)
	assertIsValidTarget(target)

	accessState.SetTargetClosed(target, closed)
	emitTargetClosed(target, closed)
}
