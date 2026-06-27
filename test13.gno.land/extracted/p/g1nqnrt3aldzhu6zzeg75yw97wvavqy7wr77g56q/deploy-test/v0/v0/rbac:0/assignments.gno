package rbac

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/ds/btree"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/ds/btreeset"
)

type assignments struct {
	degree              int
	entityUserRoleIndex *btree.StringBTree
	entityRoleUserIndex *btree.StringBTree
	userRoleEntityIndex *btree.StringBTree
}

func newAssignments(degree int) *assignments {
	return &assignments{
		degree:              degree,
		entityUserRoleIndex: btree.NewStringBTree(degree),
		entityRoleUserIndex: btree.NewStringBTree(degree),
		userRoleEntityIndex: btree.NewStringBTree(degree),
	}
}

func (as *assignments) Add(entityID string, user address, roleID uint32) {
	as.validateEntityID(entityID)

	roles := as.getOrCreateEntityUserRoleSet(entityID, user)
	if roles.Has(roleID) {
		panic("assignment already exists: entityID=" + entityID + ", user=" + user.String() + ", roleID=" + formatRoleID(roleID))
	}
	roles.Set(roleID)

	users := as.getOrCreateEntityRoleUserSet(entityID, roleID)
	users.Set(user.String())

	entities := as.getOrCreateUserRoleEntitySet(user, roleID)
	entities.Set(entityID)
}

func (as *assignments) Delete(entityID string, user address, roleID uint32) {
	as.validateEntityID(entityID)

	roles, found := as.findEntityUserRoleSet(entityID, user)
	if !found || !roles.Has(roleID) {
		panic("assignment not found: entityID=" + entityID + ", user=" + user.String() + ", roleID=" + formatRoleID(roleID))
	}
	roles.Remove(roleID)
	as.cleanupEntityUserRoleSet(entityID, user, roles)

	users, found := as.findEntityRoleUserSet(entityID, roleID)
	if found {
		users.Remove(user.String())
		as.cleanupEntityRoleUserSet(entityID, roleID, users)
	}

	entities, found := as.findUserRoleEntitySet(user, roleID)
	if found {
		entities.Remove(entityID)
		as.cleanupUserRoleEntitySet(user, roleID, entities)
	}
}

func (as *assignments) Has(entityID string, user address, roleID uint32) bool {
	as.validateEntityID(entityID)

	roles, found := as.findEntityUserRoleSet(entityID, user)
	if !found {
		return false
	}
	return roles.Has(roleID)
}

func (as *assignments) DeleteRole(roleID uint32) {
	emptyEntityRoleKeys := []string{}
	as.entityRoleUserIndex.Iterate(nil, nil, func(entityID string, roleUsersValue any) bool {
		roleUsers := castEntityRoleUserTree(entityID, roleUsersValue)
		usersValue, found := roleUsers.Get(roleID)
		if !found {
			return false
		}

		users := castAssignmentUserSet(roleID, usersValue)
		users.Iterate(nil, nil, func(userKey string) bool {
			user := address(userKey)
			if roles, found := as.findEntityUserRoleSet(entityID, user); found {
				roles.Remove(roleID)
				as.cleanupEntityUserRoleSet(entityID, user, roles)
			}
			if entities, found := as.findUserRoleEntitySet(user, roleID); found {
				entities.Remove(entityID)
				as.cleanupUserRoleEntitySet(user, roleID, entities)
			}
			return false
		})

		roleUsers.Remove(roleID)
		if roleUsers.Size() == 0 {
			emptyEntityRoleKeys = append(emptyEntityRoleKeys, entityID)
		}
		return false
	})
	for _, entityID := range emptyEntityRoleKeys {
		as.entityRoleUserIndex.Remove(entityID)
	}
}

func (as *assignments) DeleteEntity(entityID string) {
	as.validateEntityID(entityID)

	userRoles, found := as.findEntityUserRoleTree(entityID)
	if !found {
		as.entityRoleUserIndex.Remove(entityID)
		return
	}

	userRoles.Iterate(nil, nil, func(userKey string, rolesValue any) bool {
		user := address(userKey)
		roles := castAssignmentRoleSet(entityID, rolesValue)
		roles.Iterate(nil, nil, func(roleID uint32) bool {
			if entities, found := as.findUserRoleEntitySet(user, roleID); found {
				entities.Remove(entityID)
				as.cleanupUserRoleEntitySet(user, roleID, entities)
			}
			return false
		})
		return false
	})

	as.entityUserRoleIndex.Remove(entityID)
	as.entityRoleUserIndex.Remove(entityID)
}

func (as *assignments) ListRoles(entityID string, user address, page int, count int) []uint32 {
	as.validateEntityID(entityID)
	offset := pageOffset(page, count)

	roles, found := as.findEntityUserRoleSet(entityID, user)
	if !found {
		return []uint32{}
	}
	return listUint32SetByOffset(roles, offset, count)
}

func (as *assignments) ListUsers(entityID string, roleID uint32, page int, count int) []address {
	as.validateEntityID(entityID)
	offset := pageOffset(page, count)

	users, found := as.findEntityRoleUserSet(entityID, roleID)
	if !found {
		return []address{}
	}

	result := make([]address, 0, count)
	users.IterateByOffset(offset, count, func(userKey string) bool {
		result = append(result, address(userKey))
		return false
	})
	return result
}

func (as *assignments) ListEntities(user address, roleID uint32, page int, count int) []string {
	offset := pageOffset(page, count)

	entities, found := as.findUserRoleEntitySet(user, roleID)
	if !found {
		return []string{}
	}
	return listStringSetByOffset(entities, offset, count)
}

func (as *assignments) Size() int {
	size := 0
	as.entityUserRoleIndex.Iterate(nil, nil, func(entityID string, userRolesValue any) bool {
		userRoles := castEntityUserRoleTree(entityID, userRolesValue)
		userRoles.Iterate(nil, nil, func(_ string, rolesValue any) bool {
			size += castAssignmentRoleSet(entityID, rolesValue).Size()
			return false
		})
		return false
	})
	return size
}

func (as *assignments) UserSize(entityID string, user address) int {
	as.validateEntityID(entityID)

	roles, found := as.findEntityUserRoleSet(entityID, user)
	if !found {
		return 0
	}
	return roles.Size()
}

func (as *assignments) RoleSize(entityID string, roleID uint32) int {
	as.validateEntityID(entityID)

	users, found := as.findEntityRoleUserSet(entityID, roleID)
	if !found {
		return 0
	}
	return users.Size()
}

func (as *assignments) EntitySize(user address, roleID uint32) int {
	entities, found := as.findUserRoleEntitySet(user, roleID)
	if !found {
		return 0
	}
	return entities.Size()
}

func (as *assignments) findEntityUserRoleSet(entityID string, user address) (*btreeset.Uint32BTreeSet, bool) {
	userRoles, found := as.findEntityUserRoleTree(entityID)
	if !found {
		return nil, false
	}
	rolesValue, found := userRoles.Get(user.String())
	if !found {
		return nil, false
	}
	return castAssignmentRoleSet(entityID, rolesValue), true
}

func (as *assignments) getOrCreateEntityUserRoleSet(entityID string, user address) *btreeset.Uint32BTreeSet {
	userRoles := as.getOrCreateEntityUserRoleTree(entityID)
	rolesValue, found := userRoles.Get(user.String())
	if found {
		return castAssignmentRoleSet(entityID, rolesValue)
	}

	roles := btreeset.NewUint32BTreeSet(as.degree)
	userRoles.Set(user.String(), roles)
	return roles
}

func (as *assignments) findEntityUserRoleTree(entityID string) (*btree.StringBTree, bool) {
	userRolesValue, found := as.entityUserRoleIndex.Get(entityID)
	if !found {
		return nil, false
	}
	return castEntityUserRoleTree(entityID, userRolesValue), true
}

func (as *assignments) getOrCreateEntityUserRoleTree(entityID string) *btree.StringBTree {
	userRoles, found := as.findEntityUserRoleTree(entityID)
	if found {
		return userRoles
	}

	userRoles = btree.NewStringBTree(as.degree)
	as.entityUserRoleIndex.Set(entityID, userRoles)
	return userRoles
}

func (as *assignments) findEntityRoleUserSet(entityID string, roleID uint32) (*btreeset.StringBTreeSet, bool) {
	roleUsers, found := as.findEntityRoleUserTree(entityID)
	if !found {
		return nil, false
	}
	usersValue, found := roleUsers.Get(roleID)
	if !found {
		return nil, false
	}
	return castAssignmentUserSet(roleID, usersValue), true
}

func (as *assignments) getOrCreateEntityRoleUserSet(entityID string, roleID uint32) *btreeset.StringBTreeSet {
	roleUsers := as.getOrCreateEntityRoleUserTree(entityID)
	usersValue, found := roleUsers.Get(roleID)
	if found {
		return castAssignmentUserSet(roleID, usersValue)
	}

	users := btreeset.NewStringBTreeSet(as.degree)
	roleUsers.Set(roleID, users)
	return users
}

func (as *assignments) findEntityRoleUserTree(entityID string) (*btree.Uint32BTree, bool) {
	roleUsersValue, found := as.entityRoleUserIndex.Get(entityID)
	if !found {
		return nil, false
	}
	return castEntityRoleUserTree(entityID, roleUsersValue), true
}

func (as *assignments) getOrCreateEntityRoleUserTree(entityID string) *btree.Uint32BTree {
	roleUsers, found := as.findEntityRoleUserTree(entityID)
	if found {
		return roleUsers
	}

	roleUsers = btree.NewUint32BTree(as.degree)
	as.entityRoleUserIndex.Set(entityID, roleUsers)
	return roleUsers
}

func (as *assignments) findUserRoleEntitySet(user address, roleID uint32) (*btreeset.StringBTreeSet, bool) {
	roleEntities, found := as.findUserRoleEntityTree(user)
	if !found {
		return nil, false
	}
	entitiesValue, found := roleEntities.Get(roleID)
	if !found {
		return nil, false
	}
	return castAssignmentEntitySet(roleID, entitiesValue), true
}

func (as *assignments) getOrCreateUserRoleEntitySet(user address, roleID uint32) *btreeset.StringBTreeSet {
	roleEntities := as.getOrCreateUserRoleEntityTree(user)
	entitiesValue, found := roleEntities.Get(roleID)
	if found {
		return castAssignmentEntitySet(roleID, entitiesValue)
	}

	entities := btreeset.NewStringBTreeSet(as.degree)
	roleEntities.Set(roleID, entities)
	return entities
}

func (as *assignments) findUserRoleEntityTree(user address) (*btree.Uint32BTree, bool) {
	roleEntitiesValue, found := as.userRoleEntityIndex.Get(user.String())
	if !found {
		return nil, false
	}
	return castUserRoleEntityTree(user, roleEntitiesValue), true
}

func (as *assignments) getOrCreateUserRoleEntityTree(user address) *btree.Uint32BTree {
	roleEntities, found := as.findUserRoleEntityTree(user)
	if found {
		return roleEntities
	}

	roleEntities = btree.NewUint32BTree(as.degree)
	as.userRoleEntityIndex.Set(user.String(), roleEntities)
	return roleEntities
}

func (as *assignments) cleanupEntityUserRoleSet(entityID string, user address, roles *btreeset.Uint32BTreeSet) {
	if roles.Size() > 0 {
		return
	}
	userRoles, found := as.findEntityUserRoleTree(entityID)
	if !found {
		return
	}
	userRoles.Remove(user.String())
	if userRoles.Size() == 0 {
		as.entityUserRoleIndex.Remove(entityID)
	}
}

func (as *assignments) cleanupEntityRoleUserSet(entityID string, roleID uint32, users *btreeset.StringBTreeSet) {
	if users.Size() > 0 {
		return
	}
	roleUsers, found := as.findEntityRoleUserTree(entityID)
	if !found {
		return
	}
	roleUsers.Remove(roleID)
	if roleUsers.Size() == 0 {
		as.entityRoleUserIndex.Remove(entityID)
	}
}

func (as *assignments) cleanupUserRoleEntitySet(user address, roleID uint32, entities *btreeset.StringBTreeSet) {
	if entities.Size() > 0 {
		return
	}
	roleEntities, found := as.findUserRoleEntityTree(user)
	if !found {
		return
	}
	roleEntities.Remove(roleID)
	if roleEntities.Size() == 0 {
		as.userRoleEntityIndex.Remove(user.String())
	}
}

func (as *assignments) validateEntityID(entityID string) {
	if entityID == "" {
		panic("entityID required")
	}
}

func listUint32SetByOffset(set *btreeset.Uint32BTreeSet, offset int, count int) []uint32 {
	result := make([]uint32, 0, count)
	set.IterateByOffset(offset, count, func(id uint32) bool {
		result = append(result, id)
		return false
	})
	return result
}

func listStringSetByOffset(set *btreeset.StringBTreeSet, offset int, count int) []string {
	result := make([]string, 0, count)
	set.IterateByOffset(offset, count, func(id string) bool {
		result = append(result, id)
		return false
	})
	return result
}

func castEntityUserRoleTree(entityID string, userRolesValue any) *btree.StringBTree {
	userRoles, ok := userRolesValue.(*btree.StringBTree)
	if !ok {
		panic("invalid entity user role index: " + entityID)
	}
	return userRoles
}

func castEntityRoleUserTree(entityID string, roleUsersValue any) *btree.Uint32BTree {
	roleUsers, ok := roleUsersValue.(*btree.Uint32BTree)
	if !ok {
		panic("invalid entity role user index: " + entityID)
	}
	return roleUsers
}

func castUserRoleEntityTree(user address, roleEntitiesValue any) *btree.Uint32BTree {
	roleEntities, ok := roleEntitiesValue.(*btree.Uint32BTree)
	if !ok {
		panic("invalid user role entity index: " + user.String())
	}
	return roleEntities
}

func castAssignmentRoleSet(entityID string, rolesValue any) *btreeset.Uint32BTreeSet {
	roles, ok := rolesValue.(*btreeset.Uint32BTreeSet)
	if !ok {
		panic("invalid user role set: " + entityID)
	}
	return roles
}

func castAssignmentUserSet(roleID uint32, usersValue any) *btreeset.StringBTreeSet {
	users, ok := usersValue.(*btreeset.StringBTreeSet)
	if !ok {
		panic("invalid role user set: " + formatRoleID(roleID))
	}
	return users
}

func castAssignmentEntitySet(roleID uint32, entitiesValue any) *btreeset.StringBTreeSet {
	entities, ok := entitiesValue.(*btreeset.StringBTreeSet)
	if !ok {
		panic("invalid user role entity set: " + formatRoleID(roleID))
	}
	return entities
}
