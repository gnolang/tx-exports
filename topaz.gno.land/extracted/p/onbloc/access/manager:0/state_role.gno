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

func NewRoleConfig(admin RoleId, grantDelay Delay) *RoleConfig {
	return &RoleConfig{
		Members:    make(map[address]Access),
		Admin:      admin,
		GrantDelay: grantDelay,
	}
}

func (roleConfig *RoleConfig) grant(account address, now TimePoint) bool {
	_, found := roleConfig.Members[account]
	if found {
		return false
	}

	roleConfig.Members[account] = NewAccessWithDelay(now, roleConfig.GrantDelay)

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

func (roleConfig *RoleConfig) setGrantDelay(delay Delay) {
	roleConfig.GrantDelay = delay
}

func (roleConfig *RoleConfig) grantDelay() Delay {
	return roleConfig.GrantDelay
}
