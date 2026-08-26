package manager

import "strconv"

type RoleId uint64

func NewRoleId(id uint64) RoleId {
	return RoleId(id)
}

func (r RoleId) Uint64() uint64 {
	return uint64(r)
}

func (r RoleId) String() string {
	return strconv.FormatUint(uint64(r), 10)
}

type RoleConfig struct {
	Members    map[address]Access
	Admin      RoleId
	GrantDelay Delay
}

func NewRoleConfig(admin RoleId, grantDelay uint32) *RoleConfig {
	return &RoleConfig{
		Members:    make(map[address]Access),
		Admin:      admin,
		GrantDelay: NewDelay(grantDelay),
	}
}

func (roleConfig *RoleConfig) grant(account address, now TimePoint) bool {
	_, found := roleConfig.Members[account]
	if found {
		return false
	}

	roleConfig.Members[account] = NewAccessWithDelay(now, roleConfig.grantDelay(now))

	return true
}

func (roleConfig *RoleConfig) revoke(account address) bool {
	_, found := roleConfig.Members[account]
	if found {
		delete(roleConfig.Members, account)
	}

	return found
}

func (roleConfig *RoleConfig) hasMember(account address, now TimePoint) bool {
	access, found := roleConfig.Members[account]
	if !found {
		return false
	}

	return access.isActiveAt(now)
}

func (roleConfig *RoleConfig) setAdmin(admin RoleId) {
	roleConfig.Admin = admin
}

func (roleConfig *RoleConfig) adminRole() RoleId {
	return roleConfig.Admin
}

// setGrantDelay schedules newDelay behind the MinSetback setback. Callers
// read the effect timePoint via State.GetRoleGrantDelayEffect.
// OpenZeppelin: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L362-L371
// Union: https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L314-L345
func (roleConfig *RoleConfig) setGrantDelay(now TimePoint, newDelay uint32) {
	updated, _ := roleConfig.GrantDelay.WithUpdate(now, newDelay, MinSetback)
	roleConfig.GrantDelay = updated
}

// grantDelay returns the grant delay active at now.
// OpenZeppelin: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/5fd1781b1454fd1ef8e722282f86f9293cacf256/contracts/access/manager/AccessManager.sol#L194-L196
// Union: https://github.com/unionlabs/union/blob/8cff0ff34f6baa4cdb1e4650a08985dd05de0c5a/cosmwasm/access-manager/src/contract.rs#L1138-L1144
func (roleConfig *RoleConfig) grantDelay(now TimePoint) uint32 {
	return roleConfig.GrantDelay.Get(now)
}
