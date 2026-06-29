package chunk

import (
	"chain"
	"strconv"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/p/akkadia/v0/rbac"
	"gno.land/r/akkadia/v0/admin"
)

const (
	GrantMasterEvent  = "GrantMaster"
	RevokeMasterEvent = "RevokeMaster"
)

var (
	worldAuthzRBAC = rbac.NewRBAC(32)
)

func init() {
	initWorldAuthzDefinitions()
}

func initWorldAuthzDefinitions() {
	worldAuthzRBAC = rbac.NewRBAC(32)
	worldAuthzRBAC.AddRole(rbac.RoleSpec{Name: "master"})
}

// ==================== Admin Functions ====================

// GrantMaster grants master role to a user for a world (admin only)
func GrantMaster(cur realm, worldID uint32, user address) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	worldStore.AssertExists(worldID)

	if IsMaster(worldID, user) {
		panic("user " + user.String() + " is already a master for world " + strconv.FormatUint(uint64(worldID), 10))
	}

	worldAuthzRBAC.AssignRole(formatWorldID(worldID), user, "master")

	chain.Emit(
		GrantMasterEvent,
		"worldID", strconv.FormatUint(uint64(worldID), 10),
		"user", user.String(),
	)
}

// RevokeMaster revokes master role from a user for a world (admin only)
func RevokeMaster(cur realm, worldID uint32, user address) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)
	worldStore.AssertExists(worldID)

	if !IsMaster(worldID, user) {
		panic("user " + user.String() + " is not a master for world " + strconv.FormatUint(uint64(worldID), 10))
	}

	worldAuthzRBAC.UnassignRole(formatWorldID(worldID), user, "master")

	chain.Emit(
		RevokeMasterEvent,
		"worldID", strconv.FormatUint(uint64(worldID), 10),
		"user", user.String(),
	)
}

// ==================== Query Functions ====================

// IsMaster checks if a user is a master for a world
func IsMaster(worldID uint32, user address) bool {
	assertMigrationStateAvailable()
	return worldAuthzRBAC.HasUserRole(formatWorldID(worldID), user, "master")
}

// HasWorldPermission checks if a user has world-level permission.
func HasWorldPermission(worldID uint32, user address, _ string) bool {
	assertMigrationStateAvailable()
	if admin.IsAdmin(user) {
		return true
	}
	return IsMaster(worldID, user)
}

// ListWorldMasters returns masters for a world by page.
func ListWorldMasters(worldID uint32, page int, count int) []address {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	return worldAuthzRBAC.ListRoleUsers(formatWorldID(worldID), "master", page, count)
}

// GetWorldMasterSize returns the number of masters assigned to a world.
func GetWorldMasterSize(worldID uint32) int {
	assertMigrationStateAvailable()
	return worldAuthzRBAC.RoleUserSize(formatWorldID(worldID), "master")
}

// ListMasterWorlds returns worlds where a user is a master by page.
func ListMasterWorlds(user address, page int, count int) []uint32 {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	result := []uint32{}
	worlds := worldAuthzRBAC.ListEntitiesByUserRole(user, "master", page, count)
	for _, worldKey := range worlds {
		worldID, err := strconv.ParseUint(worldKey, 10, 32)
		if err != nil {
			panic("invalid master worldID: " + worldKey)
		}
		result = append(result, uint32(worldID))
	}
	return result
}

// GetMasterWorldSize returns the number of worlds where user is a master.
func GetMasterWorldSize(user address) int {
	assertMigrationStateAvailable()
	return worldAuthzRBAC.UserRoleEntitySize(user, "master")
}
