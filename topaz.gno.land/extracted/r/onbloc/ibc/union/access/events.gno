package access

import (
	"chain"
	"strconv"

	"gno.land/p/onbloc/access/manager"
)

func emitRoleLabelEvent(role manager.RoleId, label string) {
	chain.Emit(
		manager.EventTypeRoleLabel,
		manager.AttributeKeyRoleID, role.String(),
		manager.AttributeKeyLabel, label,
	)
}

func emitRoleGrantedEvent(role manager.RoleId, account address, since manager.TimePoint, newMember bool) {
	chain.Emit(
		manager.EventTypeRoleGranted,
		manager.AttributeKeyRoleID, role.String(),
		manager.AttributeKeyAccount, account.String(),
		manager.AttributeKeySince, since.String(),
		manager.AttributeKeyNewMember, strconv.FormatBool(newMember),
	)
}

func emitRoleRevokedEvent(role manager.RoleId, account address) {
	chain.Emit(
		manager.EventTypeRoleRevoked,
		manager.AttributeKeyRoleID, role.String(),
		manager.AttributeKeyAccount, account.String(),
	)
}

func emitRoleAdminChangedEvent(role manager.RoleId, admin manager.RoleId) {
	chain.Emit(
		manager.EventTypeRoleAdminChanged,
		manager.AttributeKeyRoleID, role.String(),
		manager.AttributeKeyAdmin, admin.String(),
	)
}

func emitRoleGrantDelayChangedEvent(role manager.RoleId, delay manager.Delay, since manager.TimePoint) {
	chain.Emit(
		manager.EventTypeRoleGrantDelayChanged,
		manager.AttributeKeyRoleID, role.String(),
		manager.AttributeKeyDelay, delay.String(),
		manager.AttributeKeySince, since.String(),
	)
}

func emitTargetClosedEvent(target string, closed bool) {
	chain.Emit(
		manager.EventTypeTargetClosed,
		manager.AttributeKeyTarget, target,
		manager.AttributeKeyClosed, strconv.FormatBool(closed),
	)
}

func emitTargetFunctionRoleUpdatedEvent(target string, selector manager.Selector, role manager.RoleId) {
	chain.Emit(
		manager.EventTypeTargetFunctionRoleUpdated,
		manager.AttributeKeyTarget, target,
		manager.AttributeKeySelector, string(selector),
		manager.AttributeKeyRoleID, role.String(),
	)
}
