package chunk

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/akkadia/v0/accesscontrol"
	"gno.land/p/akkadia/v0/grc721"
	"gno.land/p/akkadia/v0/rbac"
	"gno.land/r/akkadia/v0/admin"
)

const (
	CreatePermissionEvent     = "CreateChunkPermission"
	DeletePermissionEvent     = "DeleteChunkPermission"
	CreateRoleEvent           = "CreateChunkRole"
	UpdateRoleEvent           = "UpdateChunkRole"
	UpdateRolePropertiesEvent = "UpdateChunkRoleProperties"
	DeleteRoleEvent           = "DeleteChunkRole"
	AddPermissionEvent        = "AddChunkPermission"
	RemovePermissionEvent     = "RemoveChunkPermission"
	AddGrantableEvent         = "AddChunkGrantable"
	RemoveGrantableEvent      = "RemoveChunkGrantable"
	GrantRoleEvent            = "GrantChunkRole"
	RevokeRoleEvent           = "RevokeChunkRole"
)

var (
	chunkAuthzRBAC = rbac.NewRBAC(32)
)

func init() {
	initChunkAuthzDefinitions()
}

func initChunkAuthzDefinitions() {
	chunkAuthzRBAC = rbac.NewRBAC(32)

	chunkAuthzRBAC.AddPermission(rbac.Permission{Name: "block:install", Description: "Install blocks in chunk"})
	chunkAuthzRBAC.AddPermission(rbac.Permission{Name: "block:uninstall", Description: "Uninstall blocks from chunk"})

	chunkAuthzRBAC.AddRole(rbac.RoleSpec{
		Name:            "editor",
		PermissionNames: []string{"block:install", "block:uninstall"},
		Metadata:        map[string]string{"maxAssign": "0"},
		AssignmentCheck: newMaxAssignCheck(0),
	})
}

// ==================== Permission Management (Admin Only) ====================

// CreatePermission creates a new permission definition
func CreatePermission(cur realm, name string, description string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	chunkAuthzRBAC.AddPermission(rbac.Permission{Name: name, Description: description})
	chain.Emit(CreatePermissionEvent, "name", name, "description", description)
}

// DeletePermission deletes a permission and removes it from all roles
func DeletePermission(cur realm, name string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	chunkAuthzRBAC.DeletePermission(name)
	chain.Emit(DeletePermissionEvent, "name", name)
}

// AddPermissionToRole adds a permission to an existing role
func AddPermissionToRole(cur realm, roleName string, permissionName string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	chunkAuthzRBAC.AddRolePermission(roleName, permissionName)
	chain.Emit(AddPermissionEvent, "role", roleName, "permission", permissionName)
}

// RemovePermissionFromRole removes a permission from a role
func RemovePermissionFromRole(cur realm, roleName string, permissionName string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	chunkAuthzRBAC.DeleteRolePermission(roleName, permissionName)
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

	chunkAuthzRBAC.AddRole(rbac.RoleSpec{
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

	chunkAuthzRBAC.UpdateRole(roleName, rbac.RoleSpec{
		Name:            roleName,
		PermissionNames: parsePermissionNamesCSV(permissions),
		Metadata:        map[string]string{"maxAssign": strconv.Itoa(maxAssign)},
		AssignmentCheck: newMaxAssignCheck(maxAssign),
	})

	chain.Emit(UpdateRoleEvent, "name", roleName, "maxAssign", strconv.Itoa(maxAssign), "permissions", permissions)
}

// UpdateRoleProperties updates role properties from comma-separated keys and values.
func UpdateRoleProperties(cur realm, roleName string, keys string, values string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	chunkAuthzRBAC.SetRoleMetadataCSV(roleName, keys, values)

	chain.Emit(UpdateRolePropertiesEvent, "name", roleName, "keys", keys, "values", values)
}

// DeleteRole deletes a role and removes all its assignments
func DeleteRole(cur realm, roleName string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	chunkAuthzRBAC.DeleteRole(roleName)
	chain.Emit(DeleteRoleEvent, "name", roleName)
}

// ==================== Grantable Management (Admin Only) ====================

// AddGrantable allows granterRole to grant grantableRole to users
func AddGrantable(cur realm, granterRole, grantableRole string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	chunkAuthzRBAC.AddGrant(granterRole, grantableRole)
	chunkAuthzRBAC.AddRevoke(granterRole, grantableRole)
	chain.Emit(AddGrantableEvent, "granterRole", granterRole, "grantableRole", grantableRole)
}

// RemoveGrantable removes the ability for granterRole to grant grantableRole
func RemoveGrantable(cur realm, granterRole, grantableRole string) {
	assertNotFrozen()
	accesscontrol.AssertIsAdmin(0, cur, admin.IsAdmin)

	chunkAuthzRBAC.DeleteGrant(granterRole, grantableRole)
	chunkAuthzRBAC.DeleteRevoke(granterRole, grantableRole)

	chain.Emit(RemoveGrantableEvent, "granterRole", granterRole, "grantableRole", grantableRole)
}

// ==================== Role Grant/Revoke ====================

// canGrant checks if an address can grant a specific role for a chunk.
// Admin and owner can always grant any role.
// Users with roles that can grant the target role may grant it.
func canGrant(tokenID grc721.TokenID, addr address, role string) bool {
	if admin.IsAdmin(addr) {
		return true
	}

	owner := OwnerOf(tokenID)
	if owner == addr {
		return true
	}

	return chunkAuthzRBAC.CanGrant(tokenID.String(), addr, role)
}

func canRevoke(tokenID grc721.TokenID, addr address, role string) bool {
	if admin.IsAdmin(addr) {
		return true
	}

	owner := OwnerOf(tokenID)
	if owner == addr {
		return true
	}

	return chunkAuthzRBAC.CanRevoke(tokenID.String(), addr, role)
}

// GrantRole assigns a role to a user for a specific chunk.
// Owner, admin, or users with grantable permission can grant roles.
func GrantRole(cur realm, tokenID grc721.TokenID, roleName string, user address) {
	assertNotFrozen()
	if _, found := nftStore.OwnerOfSafe(tokenID); !found {
		panic("token not found: " + string(tokenID))
	}

	caller := accesscontrol.MustGetUserCaller(0, cur)
	if !canGrant(tokenID, caller, roleName) {
		panic("cannot grant role: caller lacks permission to assign role '" + roleName + "'")
	}

	getRoleInfo(roleName)
	chunkAuthzRBAC.AssignRole(tokenID.String(), user, roleName)

	chain.Emit(
		GrantRoleEvent,
		"tokenID", string(tokenID),
		"role", roleName,
		"user", user.String(),
	)
}

// RevokeRole removes a role from a user for a specific chunk.
// Owner, admin, or users with revokable permission can revoke roles.
func RevokeRole(cur realm, tokenID grc721.TokenID, roleName string, user address) {
	assertNotFrozen()
	if _, found := nftStore.OwnerOfSafe(tokenID); !found {
		panic("token not found: " + string(tokenID))
	}

	caller := accesscontrol.MustGetUserCaller(0, cur)
	if !canRevoke(tokenID, caller, roleName) {
		panic("cannot revoke role: caller lacks permission to revoke role '" + roleName + "'")
	}

	getRoleInfo(roleName)
	chunkAuthzRBAC.UnassignRole(tokenID.String(), user, roleName)

	chain.Emit(
		RevokeRoleEvent,
		"tokenID", string(tokenID),
		"role", roleName,
		"user", user.String(),
	)
}

// ==================== Permission Check ====================

// HasChunkPermission checks if a user has a specific permission for a chunk.
// Admin and chunk owner always have all chunk permissions.
func HasChunkPermission(tokenID grc721.TokenID, user address, permission string) bool {
	assertMigrationStateAvailable()
	if admin.IsAdmin(user) {
		return true
	}

	owner := OwnerOf(tokenID)
	if owner == user {
		return true
	}

	if !chunkAuthzRBAC.HasPermission(permission) {
		return false
	}
	return chunkAuthzRBAC.HasUserPermission(tokenID.String(), user, permission)
}

// HasRole checks if a user has a specific role for a chunk.
func HasRole(tokenID grc721.TokenID, user address, roleName string) bool {
	assertMigrationStateAvailable()
	if !chunkAuthzRBAC.HasRole(roleName) {
		return false
	}
	return chunkAuthzRBAC.HasUserRole(tokenID.String(), user, roleName)
}

// ==================== Query Functions ====================

func ListPermissions(page int, count int) map[string]string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	result := make(map[string]string)
	permissions := chunkAuthzRBAC.ListPermissions(page, count)
	for _, permission := range permissions {
		result[permission.Name] = permission.Description
	}
	return result
}

// GetPermissionSize returns the number of permission definitions.
func GetPermissionSize() int {
	assertMigrationStateAvailable()
	return chunkAuthzRBAC.PermissionSize()
}

// GetPermission returns detailed information about a permission.
func GetPermission(name string) map[string]string {
	assertMigrationStateAvailable()
	if !chunkAuthzRBAC.HasPermission(name) {
		return nil
	}
	permission := chunkAuthzRBAC.GetPermission(name)
	return map[string]string{
		"name":        permission.Name,
		"description": permission.Description,
	}
}

// GetRoleInfo returns detailed information about a role
func GetRoleInfo(roleName string) map[string]string {
	assertMigrationStateAvailable()
	if !chunkAuthzRBAC.HasRole(roleName) {
		return nil
	}
	role := chunkAuthzRBAC.GetRole(roleName)
	roleInfo := copyStringMap(role.Metadata)
	roleInfo["name"] = role.Name
	return roleInfo
}

// ListRoles returns available role names by page.
func ListRoles(page int, count int) []string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	result := []string{}
	roles := chunkAuthzRBAC.ListRoles(page, count)
	for _, role := range roles {
		result = append(result, role.Name)
	}
	return result
}

// GetRoleSize returns the number of role definitions.
func GetRoleSize() int {
	assertMigrationStateAvailable()
	return chunkAuthzRBAC.RoleSize()
}

// ListGrantables returns roles that granterRole can grant by page.
func ListGrantables(granterRole string, page int, count int) []string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	if !chunkAuthzRBAC.HasRole(granterRole) {
		return []string{}
	}
	return chunkAuthzRBAC.ListGrantableRoles(granterRole, page, count)
}

// GetGrantableSize returns the number of roles granterRole can grant.
func GetGrantableSize(granterRole string) int {
	assertMigrationStateAvailable()
	if !chunkAuthzRBAC.HasRole(granterRole) {
		return 0
	}
	return chunkAuthzRBAC.GrantableRoleSize(granterRole)
}

// ListUserRoles returns roles assigned to a user for a specific chunk by page.
func ListUserRoles(tokenID grc721.TokenID, user address, page int, count int) []map[string]string {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	result := []map[string]string{}

	roles := chunkAuthzRBAC.ListUserRoles(tokenID.String(), user, page, count)
	for _, roleName := range roles {
		role := chunkAuthzRBAC.GetRole(roleName)
		roleInfo := getRoleInfo(roleName)
		result = append(result, map[string]string{
			"name":        roleInfo["name"],
			"maxAssign":   roleInfo["maxAssign"],
			"permissions": strings.Join(role.PermissionNames, ","),
		})
	}

	return result
}

// GetUserRoleSize returns the number of roles assigned to a user for a chunk.
func GetUserRoleSize(tokenID grc721.TokenID, user address) int {
	assertMigrationStateAvailable()
	return chunkAuthzRBAC.UserRoleSize(tokenID.String(), user)
}

// ListRoleGrants returns users assigned to a specific role for a chunk by page.
func ListRoleGrants(tokenID grc721.TokenID, roleName string, page int, count int) []address {
	assertMigrationStateAvailable()
	assertListPageCount(page, count)
	result := []address{}
	if !chunkAuthzRBAC.HasRole(roleName) {
		return result
	}

	return chunkAuthzRBAC.ListRoleUsers(tokenID.String(), roleName, page, count)
}

// GetRoleGrantSize returns the number of users assigned to a role for a chunk.
func GetRoleGrantSize(tokenID grc721.TokenID, roleName string) int {
	assertMigrationStateAvailable()
	if !chunkAuthzRBAC.HasRole(roleName) {
		return 0
	}
	return chunkAuthzRBAC.RoleUserSize(tokenID.String(), roleName)
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
		chunkAuthzRBAC.GetPermission(perm)
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
