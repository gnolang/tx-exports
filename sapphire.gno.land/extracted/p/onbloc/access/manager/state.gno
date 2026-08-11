package manager

import "gno.land/p/nt/ufmt/v0"

type State struct {
	Roles   map[RoleId]*RoleConfig
	Targets map[string]*TargetConfig
}

func NewState() State {
	return State{
		Roles:   make(map[RoleId]*RoleConfig),
		Targets: make(map[string]*TargetConfig),
	}
}

// =================================================== GETTERS ====================================================

// CanCall reports whether caller can call target selector immediately.
// This Gno port returns only immediate authorization because scheduled
// execution and execution delay are intentionally not ported.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L140-L156
func (state *State) CanCall(caller address, target string, selector Selector) CanCallResult {
	if state.IsTargetClosed(target) {
		return NewCanCallResult(false)
	}

	role := state.GetTargetFunctionRole(target, selector)

	membership := state.HasRole(role, caller)
	if !membership.IsMember {
		return NewCanCallResult(false)
	}

	return NewCanCallResult(true)
}

// IsAuthorized is a boolean convenience wrapper around CanCall.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L140-L156
func (state *State) IsAuthorized(caller address, target string, selector Selector) bool {
	return state.CanCall(caller, target, selector).Immediate
}

// HasRole reports whether account currently has an active role membership.
// This Gno port returns membership only because execution delay is not ported.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L211-L220
func (state *State) HasRole(role RoleId, account address) HasRoleResult {
	if role == PublicRole {
		return NewHasRoleResult(true)
	}

	roleConfig := state.getRole(role)
	if roleConfig == nil {
		return NewHasRoleResult(false)
	}

	return NewHasRoleResult(roleConfig.hasMember(account, CurrentTimePoint()))
}

// GetRoleMemberSince returns when account's role membership became active,
// or zero if it is not a member. It corresponds to OZ/Union's since field;
// execution-delay fields are not ported here.
//
// OpenZeppelin: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L205
// Union: https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1165
func (state *State) GetRoleMemberSince(role RoleId, account address) TimePoint {
	roleConfig := state.getRole(role)
	if roleConfig == nil {
		return 0
	}

	access, found := roleConfig.Members[account]
	if !found {
		return 0
	}

	return access.Since
}

// GetRoleAdmin returns the admin role for role, defaulting to AdminRole.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L183-L186
func (state *State) GetRoleAdmin(role RoleId) RoleId {
	roleConfig := state.getRole(role)
	if roleConfig == nil {
		return AdminRole
	}

	return roleConfig.adminRole()
}

// GetRoleGrantDelay returns the grant delay currently in effect for role. A
// change scheduled by SetGrantDelay is not reflected until its effect timePoint.
// OpenZeppelin: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L194-L196
// Union: https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1138-L1144
func (state *State) GetRoleGrantDelay(role RoleId) uint32 {
	roleConfig := state.getRole(role)
	if roleConfig == nil {
		return 0
	}

	return roleConfig.grantDelay(CurrentTimePoint())
}

// GetRoleGrantDelayEffect returns when role's scheduled grant delay change
// takes effect. No OZ/Union equivalent; added to avoid direct field access.
func (state *State) GetRoleGrantDelayEffect(role RoleId) TimePoint {
	roleConfig := state.getRole(role)
	if roleConfig == nil {
		return 0
	}

	return roleConfig.GrantDelay.effectDate
}

// GetTargetFunctionRole returns the role required for target selector.
// Unconfigured selectors default to AdminRole in this Gno representation.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L173-L176
func (state *State) GetTargetFunctionRole(target string, selector Selector) RoleId {
	targetConfig := state.getTarget(target)
	if targetConfig == nil {
		return AdminRole
	}

	return targetConfig.functionRole(selector)
}

// IsTargetClosed reports whether target is closed.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L168-L171
func (state *State) IsTargetClosed(target string) bool {
	targetConfig := state.getTarget(target)

	return targetConfig != nil && targetConfig.isClosed()
}

// =============================================== ROLE MANAGEMENT ===============================================

// GrantRole grants role membership to account and returns true for a new member.
// This Gno port retains grant delay but intentionally omits OZ execution delay.
// OpenZeppelin references:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L233-L236
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L271-L298
func (state *State) GrantRole(role RoleId, account address) bool {
	if role == PublicRole {
		panic(errorWithDetails(errAccessManagerLockedRole, ufmt.Sprintf("role %d is locked", role)))
	}

	state.ensureRole(role)

	return state.getRole(role).grant(account, CurrentTimePoint())
}

// RevokeRole revokes role membership from account and reports whether it existed.
// OpenZeppelin references:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L238-L240
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L300-L319
func (state *State) RevokeRole(role RoleId, account address) bool {
	if role == PublicRole {
		panic(errorWithDetails(errAccessManagerLockedRole, ufmt.Sprintf("role %d is locked", role)))
	}

	state.ensureRole(role)

	if role == AdminRole && state.isLastAdmin(account) {
		panic(errAccessManagerLastAdmin)
	}

	return state.getRole(role).revoke(account)
}

// isLastAdmin reports whether account is the only currently active AdminRole
// member. Prevents bricking the system by removing the final admin.
func (state *State) isLastAdmin(account address) bool {
	adminRole := state.getRole(AdminRole)
	if adminRole == nil {
		return false
	}

	now := CurrentTimePoint()
	if !adminRole.hasMember(account, now) {
		return false
	}

	for member, access := range adminRole.Members {
		if member != account && access.isActiveAt(now) {
			return false
		}
	}

	return true
}

// RenounceRole revokes caller-confirmed role membership from account.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L243-L249
func (state *State) RenounceRole(role RoleId, account address, callerConfirmation address) bool {
	if account != callerConfirmation {
		panic(errAccessManagerBadConfirmation)
	}

	return state.RevokeRole(role, account)
}

// SetRoleAdmin sets the admin role that can grant or revoke role.
// OpenZeppelin references:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L251-L254
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L321-L337
func (state *State) SetRoleAdmin(role RoleId, admin RoleId) {
	RequireUnlockedConfigRole(role)

	state.ensureRole(role)
	state.getRole(role).setAdmin(admin)
}

// SetGrantDelay schedules newDelay behind a setback; it never overwrites the
// active delay on the spot. Callers read GetRoleGrantDelay for the current
// value or GetRoleGrantDelayEffect for the effect timePoint.
// AdminRole is not locked here (unlike SetRoleAdmin) — OZ/Union only reject PublicRole.
// OpenZeppelin: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L262-L264,L362-L371
// Union: https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L139-L148,L314-L345
func (state *State) SetGrantDelay(role RoleId, newDelay uint32) {
	if role == PublicRole {
		panic(errorWithDetails(errAccessManagerLockedRole, ufmt.Sprintf("role %d is locked", role)))
	}

	state.ensureRole(role)
	state.getRole(role).setGrantDelay(CurrentTimePoint(), newDelay)
}

// ============================================= FUNCTION MANAGEMENT ==============================================

// SetTargetFunctionRole sets the role required for target selector.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L385-L393
func (state *State) SetTargetFunctionRole(target string, selector Selector, role RoleId) {
	state.ensureTarget(target)
	state.getTarget(target).setFunctionRole(selector, role)
}

// SetTargetFunctionRoles sets the same role for multiple target selectors.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L373-L383
func (state *State) SetTargetFunctionRoles(target string, selectors []Selector, role RoleId) {
	state.ensureTarget(target)
	state.getTarget(target).setFunctionRoles(selectors, role)
}

// =============================================== MODE MANAGEMENT ================================================

// SetTargetClosed sets whether target rejects calls regardless of selector role.
// OpenZeppelin references:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L412-L416
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L418-L426
func (state *State) SetTargetClosed(target string, closed bool) {
	state.ensureTarget(target)
	state.getTarget(target).setClosed(closed)
}

// ================================================= ADMIN LOGIC ==================================================

// CanAdminRole reports whether caller has the admin role required for role.
// OpenZeppelin reference:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L652-L657
func (state *State) CanAdminRole(role RoleId, caller address) CanCallResult {
	adminRole := state.GetRoleAdmin(role)

	membership := state.HasRole(adminRole, caller)
	if !membership.IsMember {
		return NewCanCallResult(false)
	}

	return NewCanCallResult(true)
}

// CanManageTarget reports whether caller can manage target configuration.
// OpenZeppelin references:
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L101-L105
// https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L640-L650
func (state *State) CanManageTarget(caller address) CanCallResult {
	membership := state.HasRole(AdminRole, caller)
	if !membership.IsMember {
		return NewCanCallResult(false)
	}

	return NewCanCallResult(true)
}

func (state *State) getRole(role RoleId) *RoleConfig {
	return state.Roles[role]
}

func (state *State) getTarget(target string) *TargetConfig {
	return state.Targets[target]
}

func (state *State) ensureRole(role RoleId) {
	roleConfig, found := state.Roles[role]
	if !found || roleConfig == nil {
		state.Roles[role] = NewRoleConfig(AdminRole, 0)
	}
}

func (state *State) ensureTarget(target string) {
	targetConfig, found := state.Targets[target]
	if !found || targetConfig == nil {
		state.Targets[target] = NewTargetConfig(false)
	}
}
