package personal_world

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/p/akkadia/v0/rbac"
	"gno.land/r/akkadia/v0/admin"
)

const (
	CreatePermissionEvent   = "CreatePermission"
	DeletePermissionEvent   = "DeletePermission"
	CreateRoleEvent         = "CreateRole"
	UpdateRoleEvent         = "UpdateRole"
	UpdateRolePropertyEvent = "UpdateRoleProperty"
	DeleteRoleEvent         = "DeleteRole"
	AddPermissionEvent      = "AddPermission"
	RemovePermissionEvent   = "RemovePermission"
	AddGrantableEvent       = "AddGrantable"
	RemoveGrantableEvent    = "RemoveGrantable"
	GrantRoleEvent          = "GrantRole"
	RevokeRoleEvent         = "RevokeRole"
)

var (
	personalWorldAuthzRBAC = rbac.NewRBAC(32)
)

func init() {
	initAuthzDefinitions()
}

func initAuthzDefinitions() {
	personalWorldAuthzRBAC = rbac.NewRBAC(32)

	personalWorldAuthzRBAC.AddPermission(rbac.Permission{Name: "role:grant", Description: "Grant Role"})
	personalWorldAuthzRBAC.AddPermission(rbac.Permission{Name: "role:revoke", Description: "Revoke Role"})
	personalWorldAuthzRBAC.AddPermission(rbac.Permission{Name: "world:update", Description: "Update World"})
	personalWorldAuthzRBAC.AddPermission(rbac.Permission{Name: "world:expand", Description: "Expand World"})
	personalWorldAuthzRBAC.AddPermission(rbac.Permission{Name: "block:install", Description: "Install Block"})
	personalWorldAuthzRBAC.AddPermission(rbac.Permission{Name: "block:uninstall", Description: "Uninstall Block"})

	personalWorldAuthzRBAC.AddRole(rbac.RoleSpec{
		Name:            "editor",
		PermissionNames: []string{"block:install", "block:uninstall"},
		Metadata:        map[string]string{"maxAssign": "5"},
		AssignmentCheck: newMaxAssignCheck(5),
	})
}

// ==================== Permission Management (Admin Only) ====================

// CreatePermission creates a new permission definition
func CreatePermission(cur realm, name string, description string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	personalWorldAuthzRBAC.AddPermission(rbac.Permission{Name: name, Description: description})
	chain.Emit(CreatePermissionEvent, "name", name, "description", description)
}

// DeletePermission deletes a permission and removes it from all roles
func DeletePermission(cur realm, name string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	personalWorldAuthzRBAC.DeletePermission(name)
	chain.Emit(DeletePermissionEvent, "name", name)
}

// AddPermissionToRole adds a permission to an existing role
func AddPermissionToRole(cur realm, roleName string, permissionName string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	personalWorldAuthzRBAC.AddRolePermission(roleName, permissionName)
	chain.Emit(AddPermissionEvent, "role", roleName, "permission", permissionName)
}

// RemovePermissionFromRole removes a permission from a role
func RemovePermissionFromRole(cur realm, roleName string, permissionName string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	personalWorldAuthzRBAC.DeleteRolePermission(roleName, permissionName)
	chain.Emit(RemovePermissionEvent, "role", roleName, "permission", permissionName)
}

// ==================== Role Management (Admin Only) ====================

// CreateRole creates a new role with permissions
// permissions is a comma-separated string of permission names
// maxAssign: 0 = unlimited assignments
func CreateRole(cur realm, roleName string, maxAssign int, permissions string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	if maxAssign < 0 {
		panic("maxAssign must be non-negative")
	}

	personalWorldAuthzRBAC.AddRole(rbac.RoleSpec{
		Name:            roleName,
		PermissionNames: parsePermissionNamesCSV(permissions),
		Metadata:        map[string]string{"maxAssign": strconv.Itoa(maxAssign)},
		AssignmentCheck: newMaxAssignCheck(maxAssign),
	})

	chain.Emit(CreateRoleEvent, "name", roleName, "permissions", permissions)
}

// UpdateRole updates a role's maxAssign and permissions
// permissions is a comma-separated string of permission names (replaces all existing permissions)
// maxAssign: 0 = unlimited assignments
func UpdateRole(cur realm, roleName string, maxAssign int, permissions string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	if maxAssign < 0 {
		panic("maxAssign must be non-negative")
	}

	personalWorldAuthzRBAC.UpdateRole(roleName, rbac.RoleSpec{
		Name:            roleName,
		PermissionNames: parsePermissionNamesCSV(permissions),
		Metadata:        map[string]string{"maxAssign": strconv.Itoa(maxAssign)},
		AssignmentCheck: newMaxAssignCheck(maxAssign),
	})

	chain.Emit(UpdateRoleEvent, "name", roleName, "maxAssign", strconv.Itoa(maxAssign), "permissions", permissions)
}

// UpdateRoleProperty updates a single property of a role
func UpdateRoleProperty(cur realm, roleName string, key string, value string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	personalWorldAuthzRBAC.SetRoleMetadata(roleName, key, value)

	chain.Emit(UpdateRolePropertyEvent, "name", roleName, "key", key, "value", value)
}

// DeleteRole deletes a role and removes all its assignments
func DeleteRole(cur realm, roleName string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	personalWorldAuthzRBAC.DeleteRole(roleName)
	chain.Emit(DeleteRoleEvent, "name", roleName)
}

// ==================== Grantable Management (Admin Only) ====================

// AddGrantable allows granterRole to grant grantableRole to users
func AddGrantable(cur realm, granterRole, grantableRole string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	personalWorldAuthzRBAC.AddGrant(granterRole, grantableRole)
	personalWorldAuthzRBAC.AddRevoke(granterRole, grantableRole)
	chain.Emit(AddGrantableEvent, "granterRole", granterRole, "grantableRole", grantableRole)
}

// RemoveGrantable removes the ability for granterRole to grant grantableRole
func RemoveGrantable(cur realm, granterRole, grantableRole string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	personalWorldAuthzRBAC.DeleteGrant(granterRole, grantableRole)
	personalWorldAuthzRBAC.DeleteRevoke(granterRole, grantableRole)

	chain.Emit(RemoveGrantableEvent, "granterRole", granterRole, "grantableRole", grantableRole)
}

// ==================== Query Functions ====================

func ListPermissions(page int, count int) map[string]string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	result := make(map[string]string)
	permissions := personalWorldAuthzRBAC.ListPermissions(page, count)
	for _, permission := range permissions {
		result[permission.Name] = permission.Description
	}
	return result
}

func GetPermissionSize() int {
	assertMigrationStateAvailable()
	return personalWorldAuthzRBAC.PermissionSize()
}

func GetPermission(name string) map[string]string {
	assertMigrationStateAvailable()
	if !personalWorldAuthzRBAC.HasPermission(name) {
		return nil
	}
	permission := personalWorldAuthzRBAC.GetPermission(name)
	return map[string]string{
		"name":        permission.Name,
		"description": permission.Description,
	}
}

// GetRoleInfo returns detailed information about a role
func GetRoleInfo(roleName string) map[string]string {
	assertMigrationStateAvailable()
	if !personalWorldAuthzRBAC.HasRole(roleName) {
		return nil
	}
	role := personalWorldAuthzRBAC.GetRole(roleName)
	roleInfo := copyStringMap(role.Metadata)
	roleInfo["name"] = role.Name
	return roleInfo
}

func ListRoles(page int, count int) []string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	result := []string{}
	roles := personalWorldAuthzRBAC.ListRoles(page, count)
	for _, role := range roles {
		result = append(result, role.Name)
	}
	return result
}

func GetRoleSize() int {
	assertMigrationStateAvailable()
	return personalWorldAuthzRBAC.RoleSize()
}

func ListGrantables(granterRole string, page int, count int) []string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	if !personalWorldAuthzRBAC.HasRole(granterRole) {
		return []string{}
	}
	return personalWorldAuthzRBAC.ListGrantableRoles(granterRole, page, count)
}

func GetGrantableSize(granterRole string) int {
	assertMigrationStateAvailable()
	if !personalWorldAuthzRBAC.HasRole(granterRole) {
		return 0
	}
	return personalWorldAuthzRBAC.GrantableRoleSize(granterRole)
}

func getRoleInfo(roleName string) map[string]string {
	roleInfo := GetRoleInfo(roleName)
	if roleInfo == nil {
		panic("role not found: " + roleName)
	}
	return roleInfo
}

func parsePermissionNamesCSV(permissions string) []string {
	result := []string{}
	seen := map[string]bool{}
	if len(permissions) == 0 {
		return result
	}
	permList := strings.Split(permissions, ",")
	for _, perm := range permList {
		perm = strings.TrimSpace(perm)
		if len(perm) == 0 || seen[perm] {
			continue
		}
		personalWorldAuthzRBAC.GetPermission(perm)
		seen[perm] = true
		result = append(result, perm)
	}
	return result
}

func newMaxAssignCheck(maxAssign int) rbac.AssignmentCheck {
	if maxAssign == 0 {
		return nil
	}
	return func(ctx rbac.AssignmentContext) bool {
		if ctx.CurrentRoleAssignments >= maxAssign {
			panic("role assignment limit reached")
		}
		return true
	}
}

// GrantRole assigns a role to a user for a specific world
// Owner, admin, or users with grantable permission can grant roles
func GrantRole(cur realm, worldID uint32, roleName string, user address) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	assertCanGrantRole(worldID, caller, roleName)

	worldStore.AssertWorldExists(worldID)

	getRoleInfo(roleName)
	personalWorldAuthzRBAC.AssignRole(formatWorldID(worldID), user, roleName)

	chain.Emit(
		GrantRoleEvent,
		"worldID", formatWorldID(worldID),
		"role", roleName,
		"user", user.String(),
	)
}

// RevokeRole removes a role from a user for a specific world
// Owner, admin, or users with grantable permission can revoke roles
func RevokeRole(cur realm, worldID uint32, roleName string, user address) {
	assertNotFrozen()
	caller := accesscontrol.MustGetUserCaller(0, cur)
	assertCanRevokeRole(worldID, caller, roleName)

	worldStore.AssertWorldExists(worldID)

	getRoleInfo(roleName)
	personalWorldAuthzRBAC.UnassignRole(formatWorldID(worldID), user, roleName)

	chain.Emit(
		RevokeRoleEvent,
		"worldID", formatWorldID(worldID),
		"role", roleName,
		"user", user.String(),
	)
}

// ==================== Permission Check ====================

// HasPermission checks if a user has a specific permission for a world.
// Admins and owners always have all defined permissions.
func HasPermission(worldID uint32, user address, permission string) bool {
	assertMigrationStateAvailable()
	if !personalWorldAuthzRBAC.HasPermission(permission) {
		return false
	}

	if admin.IsAdmin(user) {
		return true
	}

	// Owner has all defined permissions.
	if isOwner(worldID, user) {
		return true
	}

	return personalWorldAuthzRBAC.HasUserPermission(formatWorldID(worldID), user, permission)
}

// HasRole checks if a user has a specific role for a world
func HasRole(worldID uint32, user address, role string) bool {
	assertMigrationStateAvailable()
	if !personalWorldAuthzRBAC.HasRole(role) {
		return false
	}
	return personalWorldAuthzRBAC.HasUserRole(formatWorldID(worldID), user, role)
}

// HasInstallPermission checks if caller has permission to install blocks in the world
func HasInstallPermission(worldID uint32, caller address) bool {
	return HasPermission(worldID, caller, "block:install")
}

// HasUninstallPermission checks if caller has permission to uninstall blocks from the world
func HasUninstallPermission(worldID uint32, caller address) bool {
	return HasPermission(worldID, caller, "block:uninstall")
}

func HasUpdatePermission(worldID uint32, caller address) bool {
	return HasPermission(worldID, caller, "world:update")
}

func HasExpandPermission(worldID uint32, caller address) bool {
	return HasPermission(worldID, caller, "world:expand")
}

func ListUserRoles(worldID uint32, user address, page int, count int) []map[string]string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	result := []map[string]string{}

	roles := personalWorldAuthzRBAC.ListUserRoles(formatWorldID(worldID), user, page, count)
	for _, roleName := range roles {
		role := personalWorldAuthzRBAC.GetRole(roleName)
		roleInfo := getRoleInfo(roleName)
		result = append(result, map[string]string{
			"name":        roleInfo["name"],
			"maxAssign":   roleInfo["maxAssign"],
			"permissions": strings.Join(role.PermissionNames, ","),
		})
	}

	return result
}

func GetUserRoleSize(worldID uint32, user address) int {
	assertMigrationStateAvailable()
	return personalWorldAuthzRBAC.UserRoleSize(formatWorldID(worldID), user)
}

func ListRoleGrants(worldID uint32, roleName string, page int, count int) []address {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	if !personalWorldAuthzRBAC.HasRole(roleName) {
		return []address{}
	}
	return personalWorldAuthzRBAC.ListRoleUsers(formatWorldID(worldID), roleName, page, count)
}

func GetRoleGrantSize(worldID uint32, roleName string) int {
	assertMigrationStateAvailable()
	if !personalWorldAuthzRBAC.HasRole(roleName) {
		return 0
	}
	return personalWorldAuthzRBAC.RoleUserSize(formatWorldID(worldID), roleName)
}

func ListWorldIDsByUserRole(user address, roleName string, page int, count int) []uint32 {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	getRoleInfo(roleName)

	result := []uint32{}
	worldIDs := personalWorldAuthzRBAC.ListEntitiesByUserRole(user, roleName, page, count)
	for _, worldKey := range worldIDs {
		worldID, err := strconv.ParseUint(worldKey, 10, 32)
		if err != nil {
			panic("invalid worldID: " + worldKey)
		}
		result = append(result, uint32(worldID))
	}
	return result
}

func GetUserRoleWorldSize(user address, roleName string) int {
	assertMigrationStateAvailable()
	if !personalWorldAuthzRBAC.HasRole(roleName) {
		return 0
	}
	return personalWorldAuthzRBAC.UserRoleEntitySize(user, roleName)
}

// ==================== Helper Functions ====================

func isOwner(worldID uint32, addr address) bool {
	return worldStore.IsOwner(worldID, addr)
}

// hasGrantableRole checks whether any caller role can manage the target role.
func hasGrantableRole(worldID uint32, addr address, roleName string) bool {
	return personalWorldAuthzRBAC.CanGrant(formatWorldID(worldID), addr, roleName)
}

func hasRevokableRole(worldID uint32, addr address, roleName string) bool {
	return personalWorldAuthzRBAC.CanRevoke(formatWorldID(worldID), addr, roleName)
}

// cleanupWorldAuthorization removes all role assignments for a deleted world
func cleanupWorldAuthorization(worldID uint32) {
	personalWorldAuthzRBAC.DeleteEntity(formatWorldID(worldID))
}
