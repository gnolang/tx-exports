package rbac

type RBAC struct {
	permissions   *permissions
	roles         *roles
	grants        *grants
	revokes       *grants
	assignments   *assignments
	callbackDepth int
}

// NewRBAC creates an unauthenticated library helper.
// Owning realms must keep the returned pointer private and expose their own
// cur realm authenticated wrappers for every mutating operation.
func NewRBAC(degree int) *RBAC {
	return &RBAC{
		permissions: newPermissions(degree),
		roles:       newRoles(degree),
		grants:      newGrants(degree),
		revokes:     newGrants(degree),
		assignments: newAssignments(degree),
	}
}

// AddPermission is expected to be called only by an owning realm's admin
// wrapper. RBAC is a /p/ helper and cannot authenticate callers itself.
func (r *RBAC) AddPermission(p Permission) {
	r.assertNotInCallback()
	r.validatePermission(p)
	r.permissions.Add(p.Name, p.Description)
}

// UpdatePermission is expected to be called only by an owning realm's admin
// wrapper. RBAC is a /p/ helper and cannot authenticate callers itself.
func (r *RBAC) UpdatePermission(name string, p Permission) {
	r.assertNotInCallback()
	r.validatePermission(p)
	r.permissions.Update(name, p.Name, p.Description)
}

// DeletePermission is expected to be called only by an owning realm's admin
// wrapper. RBAC is a /p/ helper and cannot authenticate callers itself.
func (r *RBAC) DeletePermission(name string) {
	r.assertNotInCallback()
	stored := r.permissions.permission(name)
	r.roles.DeletePermissionFromAll(stored.ID)
	r.permissions.Delete(name)
}

func (r *RBAC) GetPermission(name string) Permission {
	return r.permissionToPermission(r.permissions.Get(name))
}

func (r *RBAC) HasPermission(name string) bool {
	return r.permissions.Has(name)
}

func (r *RBAC) ListPermissions(page int, count int) []Permission {
	storedPermissions := r.permissions.List(page, count)
	result := make([]Permission, 0, len(storedPermissions))
	for _, stored := range storedPermissions {
		result = append(result, r.permissionToPermission(stored))
	}
	return result
}

func (r *RBAC) PermissionSize() int {
	return r.permissions.Size()
}

// AddRole is expected to be called only by an owning realm's admin wrapper.
// RoleSpec may contain trusted policy code through AssignmentCheck.
func (r *RBAC) AddRole(role RoleSpec) {
	r.assertNotInCallback()
	r.validateRole(role)
	r.roles.Add(role.Name, role.Description, r.permissionIDs(role.PermissionNames), role.Metadata, role.AssignmentCheck)
}

// UpdateRole is expected to be called only by an owning realm's admin wrapper.
// RoleSpec may replace trusted policy code through AssignmentCheck.
func (r *RBAC) UpdateRole(name string, role RoleSpec) {
	r.assertNotInCallback()
	r.validateRole(role)
	r.roles.Update(name, role.Name, role.Description, r.permissionIDs(role.PermissionNames), role.Metadata, role.AssignmentCheck)
}

// DeleteRole is expected to be called only by an owning realm's admin wrapper.
func (r *RBAC) DeleteRole(name string) {
	r.assertNotInCallback()
	stored := r.roles.role(name)
	r.grants.DeleteRole(stored.ID)
	r.revokes.DeleteRole(stored.ID)
	r.assignments.DeleteRole(stored.ID)
	r.roles.Delete(name)
}

func (r *RBAC) GetRole(name string) Role {
	return r.roleToRole(r.roles.Get(name))
}

func (r *RBAC) HasRole(name string) bool {
	return r.roles.Has(name)
}

func (r *RBAC) ListRoles(page int, count int) []Role {
	storedRoles := r.roles.List(page, count)
	result := make([]Role, 0, len(storedRoles))
	for _, stored := range storedRoles {
		result = append(result, r.roleToRole(stored))
	}
	return result
}

func (r *RBAC) RoleSize() int {
	return r.roles.Size()
}

func (r *RBAC) GetRoleMetadata(roleName string) map[string]string {
	return r.roles.Metadata(roleName)
}

// SetRoleMetadata is expected to be called only by an owning realm's admin
// wrapper.
func (r *RBAC) SetRoleMetadata(roleName string, key string, value string) {
	r.assertNotInCallback()
	r.roles.SetMetadata(roleName, key, value)
}

// SetRoleMetadataCSV updates role metadata from comma-separated keys and
// values. It validates the full batch before mutating stored metadata.
func (r *RBAC) SetRoleMetadataCSV(roleName string, keys string, values string) {
	r.assertNotInCallback()
	r.roles.SetMetadataCSV(roleName, keys, values)
}

// AddRolePermission is expected to be called only by an owning realm's admin
// wrapper.
func (r *RBAC) AddRolePermission(roleName string, permissionName string) {
	r.assertNotInCallback()
	role := r.roles.role(roleName)
	permission := r.permissions.permission(permissionName)
	if role.HasPermission(permission.ID) {
		panic("role already has permission: role=" + role.Name + ", permission=" + permission.Name)
	}
	role.AddPermission(permission.ID)
}

// DeleteRolePermission is expected to be called only by an owning realm's
// admin wrapper.
func (r *RBAC) DeleteRolePermission(roleName string, permissionName string) {
	r.assertNotInCallback()
	role := r.roles.role(roleName)
	permission := r.permissions.permission(permissionName)
	if !role.HasPermission(permission.ID) {
		panic("role permission not found: role=" + role.Name + ", permission=" + permission.Name)
	}
	role.DeletePermission(permission.ID)
}

func (r *RBAC) HasRolePermission(roleName string, permissionName string) bool {
	role := r.roles.role(roleName)
	permission := r.permissions.permission(permissionName)
	return role.HasPermission(permission.ID)
}

// AddGrant is expected to be called only by an owning realm's admin wrapper.
func (r *RBAC) AddGrant(granterRoleName string, granteeRoleName string) {
	r.assertNotInCallback()
	granter := r.roles.role(granterRoleName)
	grantee := r.roles.role(granteeRoleName)
	if r.grants.Has(granter.ID, grantee.ID) {
		panic("grant already exists: granter=" + granter.Name + ", grantee=" + grantee.Name)
	}
	r.grants.Add(granter.ID, grantee.ID)
}

// DeleteGrant is expected to be called only by an owning realm's admin wrapper.
func (r *RBAC) DeleteGrant(granterRoleName string, granteeRoleName string) {
	r.assertNotInCallback()
	granter := r.roles.role(granterRoleName)
	grantee := r.roles.role(granteeRoleName)
	if !r.grants.Has(granter.ID, grantee.ID) {
		panic("grant not found: granter=" + granter.Name + ", grantee=" + grantee.Name)
	}
	r.grants.Delete(granter.ID, grantee.ID)
}

func (r *RBAC) canRoleGrant(granterRoleName string, granteeRoleName string) bool {
	granter := r.roles.role(granterRoleName)
	grantee := r.roles.role(granteeRoleName)
	return r.grants.Has(granter.ID, grantee.ID)
}

func (r *RBAC) ListGrantableRoles(granterRoleName string, page int, count int) []string {
	granter := r.roles.role(granterRoleName)
	return r.roleNames(r.grants.ListGrantees(granter.ID, page, count))
}

func (r *RBAC) GrantableRoleSize(granterRoleName string) int {
	granter := r.roles.role(granterRoleName)
	return r.grants.GranteeSize(granter.ID)
}

func (r *RBAC) GrantSize() int {
	return r.grants.Size()
}

// CanGrant checks whether granter has any role in entityID that can grant
// granteeRoleName. Owner/admin bypass rules belong in the owning realm wrapper.
func (r *RBAC) CanGrant(entityID string, granter address, granteeRoleName string) bool {
	grantee := r.roles.role(granteeRoleName)
	granterRoleIDs := r.assignments.ListRoles(entityID, granter, 1, r.assignments.UserSize(entityID, granter))
	for _, granterRoleID := range granterRoleIDs {
		if r.grants.Has(granterRoleID, grantee.ID) {
			return true
		}
	}
	return false
}

// AddRevoke is expected to be called only by an owning realm's admin wrapper.
func (r *RBAC) AddRevoke(revokerRoleName string, revokeeRoleName string) {
	r.assertNotInCallback()
	revoker := r.roles.role(revokerRoleName)
	revokee := r.roles.role(revokeeRoleName)
	if r.revokes.Has(revoker.ID, revokee.ID) {
		panic("revoke already exists: revoker=" + revoker.Name + ", revokee=" + revokee.Name)
	}
	r.revokes.Add(revoker.ID, revokee.ID)
}

// DeleteRevoke is expected to be called only by an owning realm's admin wrapper.
func (r *RBAC) DeleteRevoke(revokerRoleName string, revokeeRoleName string) {
	r.assertNotInCallback()
	revoker := r.roles.role(revokerRoleName)
	revokee := r.roles.role(revokeeRoleName)
	if !r.revokes.Has(revoker.ID, revokee.ID) {
		panic("revoke not found: revoker=" + revoker.Name + ", revokee=" + revokee.Name)
	}
	r.revokes.Delete(revoker.ID, revokee.ID)
}

func (r *RBAC) ListRevokableRoles(revokerRoleName string, page int, count int) []string {
	revoker := r.roles.role(revokerRoleName)
	return r.roleNames(r.revokes.ListGrantees(revoker.ID, page, count))
}

func (r *RBAC) RevokableRoleSize(revokerRoleName string) int {
	revoker := r.roles.role(revokerRoleName)
	return r.revokes.GranteeSize(revoker.ID)
}

func (r *RBAC) RevokeSize() int {
	return r.revokes.Size()
}

// CanRevoke checks whether revoker has any role in entityID that can revoke
// revokeeRoleName. Owner/admin bypass rules belong in the owning realm wrapper.
func (r *RBAC) CanRevoke(entityID string, revoker address, revokeeRoleName string) bool {
	revokee := r.roles.role(revokeeRoleName)
	revokerRoleIDs := r.assignments.ListRoles(entityID, revoker, 1, r.assignments.UserSize(entityID, revoker))
	for _, revokerRoleID := range revokerRoleIDs {
		if r.revokes.Has(revokerRoleID, revokee.ID) {
			return true
		}
	}
	return false
}

// AssignRole trusts the supplied user address.
// Self-assignment wrappers must derive user from cur.Previous().Address()
// instead of accepting it from caller input. Admin wrappers may pass an
// explicit target user after performing their own authorization.
// Special/system role wrappers may call this directly after their own policy
// checks. User-driven grant wrappers should call CanGrant first, then call
// AssignRole only when the granter is allowed to grant roleName in entityID.
func (r *RBAC) AssignRole(entityID string, user address, roleName string) {
	r.assertNotInCallback()
	role := r.roles.role(roleName)
	if r.assignments.Has(entityID, user, role.ID) {
		panic("assignment already exists: entityID=" + entityID + ", user=" + user.String() + ", role=" + role.Name)
	}
	r.assertCanAssignRole(entityID, user, role)
	r.assignments.Add(entityID, user, role.ID)
}

// UnassignRole trusts the supplied user address.
// Special/system role wrappers may call this directly after their own policy
// checks. User-driven revoke wrappers should call CanRevoke first, then call
// UnassignRole only when the revoker is allowed to revoke roleName in entityID.
func (r *RBAC) UnassignRole(entityID string, user address, roleName string) {
	r.assertNotInCallback()
	role := r.roles.role(roleName)
	if !r.assignments.Has(entityID, user, role.ID) {
		panic("assignment not found: entityID=" + entityID + ", user=" + user.String() + ", role=" + role.Name)
	}
	r.assignments.Delete(entityID, user, role.ID)
}

// DeleteEntity is expected to be called only by an owning realm's admin or
// entity lifecycle wrapper after verifying the entity can be deleted.
func (r *RBAC) DeleteEntity(entityID string) {
	r.assertNotInCallback()
	r.assignments.DeleteEntity(entityID)
}

func (r *RBAC) HasUserRole(entityID string, user address, roleName string) bool {
	role := r.roles.role(roleName)
	return r.assignments.Has(entityID, user, role.ID)
}

func (r *RBAC) HasUserPermission(entityID string, user address, permissionName string) bool {
	permission := r.permissions.permission(permissionName)
	roleIDs := r.assignments.ListRoles(entityID, user, 1, r.assignments.UserSize(entityID, user))
	for _, roleID := range roleIDs {
		if r.roles.roleByID(roleID).HasPermission(permission.ID) {
			return true
		}
	}
	return false
}

func (r *RBAC) ListUserRoles(entityID string, user address, page int, count int) []string {
	return r.roleNames(r.assignments.ListRoles(entityID, user, page, count))
}

func (r *RBAC) UserRoleSize(entityID string, user address) int {
	return r.assignments.UserSize(entityID, user)
}

func (r *RBAC) ListRoleUsers(entityID string, roleName string, page int, count int) []address {
	role := r.roles.role(roleName)
	return r.assignments.ListUsers(entityID, role.ID, page, count)
}

func (r *RBAC) RoleUserSize(entityID string, roleName string) int {
	role := r.roles.role(roleName)
	return r.assignments.RoleSize(entityID, role.ID)
}

func (r *RBAC) ListEntitiesByUserRole(user address, roleName string, page int, count int) []string {
	role := r.roles.role(roleName)
	return r.assignments.ListEntities(user, role.ID, page, count)
}

func (r *RBAC) UserRoleEntitySize(user address, roleName string) int {
	role := r.roles.role(roleName)
	return r.assignments.EntitySize(user, role.ID)
}

func (r *RBAC) AssignmentSize() int {
	return r.assignments.Size()
}

func (r *RBAC) validatePermission(p Permission) {
	r.permissions.validateName(p.Name)
}

func (r *RBAC) validateRole(role RoleSpec) {
	r.roles.validateName(role.Name)
	for key := range role.Metadata {
		r.roles.validateMetadataKey(key)
	}
	seenPermissionNames := map[string]bool{}
	for _, permissionName := range role.PermissionNames {
		if seenPermissionNames[permissionName] {
			panic("duplicate role permission: " + permissionName)
		}
		seenPermissionNames[permissionName] = true
		r.permissions.permission(permissionName)
	}
}

func (r *RBAC) permissionIDs(permissionNames []string) []uint32 {
	permissionIDs := make([]uint32, 0, len(permissionNames))
	for _, permissionName := range permissionNames {
		permissionIDs = append(permissionIDs, r.permissions.permission(permissionName).ID)
	}
	return permissionIDs
}

func (r *RBAC) permissionNames(permissionIDs []uint32) []string {
	permissionNames := make([]string, 0, len(permissionIDs))
	for _, permissionID := range permissionIDs {
		permissionNames = append(permissionNames, r.permissions.permissionByID(permissionID).Name)
	}
	return permissionNames
}

func (r *RBAC) roleNames(roleIDs []uint32) []string {
	roleNames := make([]string, 0, len(roleIDs))
	for _, roleID := range roleIDs {
		roleNames = append(roleNames, r.roles.roleByID(roleID).Name)
	}
	return roleNames
}

func (r *RBAC) assertCanAssignRole(entityID string, user address, role *role) {
	if role.assignmentCheck == nil {
		return
	}

	ctx := AssignmentContext{
		EntityID:               entityID,
		User:                   user,
		RoleName:               role.Name,
		CurrentRoleAssignments: r.assignments.RoleSize(entityID, role.ID),
		UserRoleCount:          r.assignments.UserSize(entityID, user),
	}
	r.inCallback()
	defer r.outCallback()
	if !role.assignmentCheck(ctx) {
		panic("role assignment rejected: role=" + role.Name + ", entityID=" + entityID + ", user=" + user.String())
	}
}

func (r *RBAC) inCallback() {
	r.callbackDepth += 1
}

func (r *RBAC) outCallback() {
	r.callbackDepth -= 1
}

func (r *RBAC) assertNotInCallback() {
	if r.callbackDepth > 0 {
		panic("rbac mutation during assignment callback")
	}
}

func (r *RBAC) permissionToPermission(stored *permission) Permission {
	return Permission{
		Name:        stored.Name,
		Description: stored.Description,
	}
}

func (r *RBAC) roleToRole(stored *role) Role {
	return Role{
		Name:            stored.Name,
		Description:     stored.Description,
		PermissionNames: r.permissionNames(stored.PermissionIDs()),
		Metadata:        copyMetadata(stored.metadata),
	}
}
