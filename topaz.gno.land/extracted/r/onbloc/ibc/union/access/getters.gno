package access

import "gno.land/p/onbloc/access/manager"

// HasRole returns role membership status for account.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1172-L1197
func HasRole(role manager.RoleId, account address) manager.HasRoleResult {
	return accessState.HasRole(role, account)
}

// GetRoleAdmin returns the admin role configured for role.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1119-L1126
func GetRoleAdmin(role manager.RoleId) manager.RoleId {
	return accessState.GetRoleAdmin(role)
}

// GetRoleGrantDelay returns the grant delay configured for role.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1137-L1145
func GetRoleGrantDelay(role manager.RoleId) manager.Delay {
	return accessState.GetRoleGrantDelay(role)
}

// GetFunctionRole returns the selector role for targetPath.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1091-L1107
func GetFunctionRole(targetPath string, selector manager.Selector) manager.RoleId {
	return GetTargetFunctionRole(targetPath, selector)
}

// GetTargetFunctionRole returns the selector role for targetPath.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1091-L1107
func GetTargetFunctionRole(targetPath string, selector manager.Selector) manager.RoleId {
	return accessState.GetTargetFunctionRole(targetPath, selector)
}

// IsTargetClosed reports whether targetPath is closed.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1082-L1089
func IsTargetClosed(targetPath string) bool {
	return accessState.IsTargetClosed(targetPath)
}

// CanCall reports whether caller can call selector on targetPath.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1033-L1068
func CanCall(targetPath string, selector manager.Selector, caller address) manager.CanCallResult {
	return accessState.CanCall(caller, targetPath, selector)
}

// IsAuthorized reports immediate call authorization for targetPath.
// Union reference:
// https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1033-L1068
func IsAuthorized(targetPath string, selector manager.Selector, caller address) bool {
	return accessState.IsAuthorized(caller, targetPath, selector)
}

// CanAdminRole reports whether caller can administer role.
func CanAdminRole(role manager.RoleId, caller address) manager.CanCallResult {
	return accessState.CanAdminRole(role, caller)
}

// CanManageTarget reports whether caller can manage target configuration.
func CanManageTarget(caller address) manager.CanCallResult {
	return accessState.CanManageTarget(caller)
}
