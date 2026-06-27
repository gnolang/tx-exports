package rbac

import (
	"strconv"
	"strings"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/ds/btree"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/ds/btreeset"
)

const maxRoleID uint32 = 4294967295

type role struct {
	ID              uint32
	Name            string
	Description     string
	metadata        map[string]string
	permissionIDs   *btreeset.Uint32BTreeSet
	assignmentCheck AssignmentCheck
}

func (r *role) AddPermission(permissionID uint32) {
	if r.permissionIDs.Has(permissionID) {
		panic("role already has permission: role=" + r.Name + ", permissionID=" + formatRoleID(permissionID))
	}
	r.permissionIDs.Set(permissionID)
}

func (r *role) HasPermission(permissionID uint32) bool {
	return r.permissionIDs.Has(permissionID)
}

func (r *role) DeletePermission(permissionID uint32) {
	if !r.permissionIDs.Has(permissionID) {
		panic("role permission not found: role=" + r.Name + ", permissionID=" + formatRoleID(permissionID))
	}
	r.permissionIDs.Remove(permissionID)
}

func (r *role) PermissionIDs() []uint32 {
	result := make([]uint32, 0, r.permissionIDs.Size())
	r.permissionIDs.Iterate(nil, nil, func(permissionID uint32) bool {
		result = append(result, permissionID)
		return false
	})
	return result
}

type roles struct {
	idCounter uint32
	degree    int
	roleMap   *btree.Uint32BTree
	nameIndex *btree.StringBTree
}

func newRoles(degree int) *roles {
	return &roles{
		degree:    degree,
		roleMap:   btree.NewUint32BTree(degree),
		nameIndex: btree.NewStringBTree(degree),
	}
}

func (rs *roles) Size() int {
	return rs.roleMap.Size()
}

func (rs *roles) Add(name string, description string, permissionIDs []uint32, metadata map[string]string, assignmentCheck AssignmentCheck) {
	rs.validateName(name)
	if rs.nameIndex.Has(name) {
		panic("role already exists: " + name)
	}

	id := rs.nextID()
	stored := &role{
		ID:              id,
		Name:            name,
		Description:     description,
		metadata:        copyMetadata(metadata),
		permissionIDs:   permissionIDSet(permissionIDs, rs.degree),
		assignmentCheck: assignmentCheck,
	}
	rs.roleMap.Set(id, stored)
	rs.nameIndex.Set(stored.Name, id)
}

func (rs *roles) Update(name string, newName string, description string, permissionIDs []uint32, metadata map[string]string, assignmentCheck AssignmentCheck) {
	rs.validateName(name)
	rs.validateName(newName)

	stored := rs.role(name)
	if name != newName && rs.nameIndex.Has(newName) {
		panic("role already exists: " + newName)
	}

	storedPermissionIDs := permissionIDSet(permissionIDs, rs.degree)
	if stored.Name != newName {
		rs.nameIndex.Remove(stored.Name)
		rs.nameIndex.Set(newName, stored.ID)
		stored.Name = newName
	}
	stored.Description = description
	ensureMetadata(stored)
	mergeMetadata(stored.metadata, metadata)
	stored.permissionIDs = storedPermissionIDs
	stored.assignmentCheck = assignmentCheck
}

func (rs *roles) Delete(name string) {
	stored := rs.role(name)
	rs.roleMap.Remove(stored.ID)
	rs.nameIndex.Remove(stored.Name)
}

func (rs *roles) Has(name string) bool {
	rs.validateName(name)
	return rs.nameIndex.Has(name)
}

func (rs *roles) Get(name string) *role {
	return rs.role(name)
}

func (rs *roles) List(page int, count int) []*role {
	offset := pageOffset(page, count)
	result := make([]*role, 0, count)
	rs.nameIndex.IterateByOffset(offset, count, func(_ string, idValue any) bool {
		id, ok := idValue.(uint32)
		if !ok {
			panic("invalid role index")
		}
		result = append(result, rs.roleByID(id))
		return false
	})
	return result
}

func (rs *roles) AddPermission(roleName string, permissionID uint32) {
	stored := rs.role(roleName)
	stored.AddPermission(permissionID)
}

func (rs *roles) DeletePermission(roleName string, permissionID uint32) {
	stored := rs.role(roleName)
	stored.DeletePermission(permissionID)
}

func (rs *roles) DeletePermissionFromAll(permissionID uint32) {
	rs.roleMap.Iterate(nil, nil, func(_ uint32, roleValue any) bool {
		stored, ok := roleValue.(*role)
		if !ok {
			panic("invalid role")
		}
		stored.permissionIDs.Remove(permissionID)
		return false
	})
}

func (rs *roles) HasPermission(roleName string, permissionID uint32) bool {
	stored := rs.role(roleName)
	return stored.HasPermission(permissionID)
}

func (rs *roles) Metadata(name string) map[string]string {
	return copyMetadata(rs.role(name).metadata)
}

func (rs *roles) SetMetadata(name string, key string, value string) {
	rs.validateMutableMetadataKey(key)
	stored := rs.role(name)
	ensureMetadata(stored)
	stored.metadata[key] = value
}

func (rs *roles) SetMetadataCSV(name string, keys string, values string) {
	pending := rs.parseMetadataCSV(keys, values)
	stored := rs.role(name)
	ensureMetadata(stored)
	mergeMetadata(stored.metadata, pending)
}

func (rs *roles) role(name string) *role {
	rs.validateName(name)

	idValue, found := rs.nameIndex.Get(name)
	if !found {
		panic("role not found: " + name)
	}
	id, ok := idValue.(uint32)
	if !ok {
		panic("invalid role index")
	}
	return rs.roleByID(id)
}

func (rs *roles) roleByID(id uint32) *role {
	roleValue, found := rs.roleMap.Get(id)
	if !found {
		panic("role not found: " + formatRoleID(id))
	}
	stored, ok := roleValue.(*role)
	if !ok {
		panic("invalid role: " + formatRoleID(id))
	}
	return stored
}

func (rs *roles) nextID() uint32 {
	if rs.idCounter == maxRoleID {
		panic("role id exhausted")
	}
	id := rs.idCounter
	rs.idCounter += 1
	return id
}

func (rs *roles) validateName(name string) {
	if name == "" {
		panic("role name required")
	}
}

func (rs *roles) validateMetadataKey(key string) {
	if key == "" {
		panic("role property key must be not empty")
	}
	if key == "name" {
		panic("reserved key: " + key)
	}
}

func (rs *roles) validateMutableMetadataKey(key string) {
	rs.validateMetadataKey(key)
	if key == "maxAssign" {
		panic("reserved key: " + key)
	}
}

func (rs *roles) parseMetadataCSV(keys string, values string) map[string]string {
	if keys == "" {
		panic("role property keys must be not empty")
	}
	if values == "" {
		panic("role property values must be not empty")
	}

	pending := map[string]string{}
	keyStart, valStart := 0, 0
	keyIdx, valIdx := 0, 0
	for {
		for keyIdx < len(keys) && keys[keyIdx] != ',' {
			keyIdx++
		}
		for valIdx < len(values) && values[valIdx] != ',' {
			valIdx++
		}

		key := strings.TrimSpace(keys[keyStart:keyIdx])
		value := values[valStart:valIdx]
		if key == "" {
			panic("role property key must be not empty")
		}
		if strings.TrimSpace(value) == "" {
			panic("role property value must be not empty")
		}
		rs.validateMutableMetadataKey(key)
		pending[key] = value

		keyEnd := keyIdx >= len(keys)
		valEnd := valIdx >= len(values)
		if keyEnd != valEnd {
			panic("role property keys and values count mismatch")
		}
		if keyEnd {
			break
		}

		keyIdx++
		valIdx++
		keyStart = keyIdx
		valStart = valIdx
	}
	return pending
}

func permissionIDSet(permissionIDs []uint32, degree int) *btreeset.Uint32BTreeSet {
	result := btreeset.NewUint32BTreeSet(degree)
	for _, permissionID := range permissionIDs {
		if result.Has(permissionID) {
			panic("duplicate role permission: " + formatRoleID(permissionID))
		}
		result.Set(permissionID)
	}
	return result
}

func copyMetadata(source map[string]string) map[string]string {
	result := map[string]string{}
	for key, value := range source {
		result[key] = value
	}
	return result
}

func ensureMetadata(stored *role) {
	if stored.metadata == nil {
		stored.metadata = map[string]string{}
	}
}

func mergeMetadata(target map[string]string, source map[string]string) {
	for key, value := range source {
		target[key] = value
	}
}

func formatRoleID(id uint32) string {
	return strconv.FormatUint(uint64(id), 10)
}
