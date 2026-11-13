package keeper

import (
	"chain"
	"strconv"

	"gno.land/p/gnoswap/order/access/manager/v0"
)

func emitRoleLabel(role manager.RoleId, label string) {
	chain.Emit(
		manager.EventTypeRoleLabel,
		manager.AttributeKeyRoleID, role.String(),
		manager.AttributeKeyLabel, label,
	)
}

func emitRoleGranted(role manager.RoleId, account address, since manager.TimePoint, newMember bool) {
	chain.Emit(
		manager.EventTypeRoleGranted,
		manager.AttributeKeyRoleID, role.String(),
		manager.AttributeKeyAccount, account.String(),
		manager.AttributeKeySince, since.String(),
		manager.AttributeKeyNewMember, strconv.FormatBool(newMember),
	)
}

func emitRoleRevoked(role manager.RoleId, account address) {
	chain.Emit(
		manager.EventTypeRoleRevoked,
		manager.AttributeKeyRoleID, role.String(),
		manager.AttributeKeyAccount, account.String(),
	)
}

func emitRoleGrantDelayChanged(role manager.RoleId, delay uint32, since manager.TimePoint) {
	chain.Emit(
		manager.EventTypeRoleGrantDelayChanged,
		manager.AttributeKeyRoleID, role.String(),
		manager.AttributeKeyDelay, strconv.FormatUint(uint64(delay), 10),
		manager.AttributeKeySince, since.String(),
	)
}

func emitTargetClosed(target string, closed bool) {
	chain.Emit(
		manager.EventTypeTargetClosed,
		manager.AttributeKeyTarget, target,
		manager.AttributeKeyClosed, strconv.FormatBool(closed),
	)
}

func emitTargetFunctionRoleUpdated(target string, selector manager.Selector, role manager.RoleId) {
	chain.Emit(
		manager.EventTypeTargetFunctionRoleUpdated,
		manager.AttributeKeyTarget, target,
		manager.AttributeKeySelector, string(selector),
		manager.AttributeKeyRoleID, role.String(),
	)
}
