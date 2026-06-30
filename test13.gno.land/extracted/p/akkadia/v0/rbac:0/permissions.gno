package rbac

import "gno.land/p/akkadia/v0/ds/btree"

const maxPermissionID uint32 = 4294967295

type permission struct {
	ID          uint32
	Name        string
	Description string
}

type permissions struct {
	idCounter     uint32
	permissionMap *btree.Uint32BTree
	nameIndex     *btree.StringBTree
}

func newPermissions(degree int) *permissions {
	return &permissions{
		permissionMap: btree.NewUint32BTree(degree),
		nameIndex:     btree.NewStringBTree(degree),
	}
}

func (ps *permissions) Size() int {
	return ps.permissionMap.Size()
}

func (ps *permissions) Add(name string, description string) {
	ps.validateName(name)
	if ps.nameIndex.Has(name) {
		panic("permission already exists: " + name)
	}

	id := ps.nextID()
	stored := &permission{
		ID:          id,
		Name:        name,
		Description: description,
	}
	ps.permissionMap.Set(id, stored)
	ps.nameIndex.Set(stored.Name, id)
}

func (ps *permissions) Update(name string, newName string, description string) {
	ps.validateName(name)
	ps.validateName(newName)

	stored := ps.permission(name)
	if name != newName && ps.nameIndex.Has(newName) {
		panic("permission already exists: " + newName)
	}

	if stored.Name != newName {
		ps.nameIndex.Remove(stored.Name)
		ps.nameIndex.Set(newName, stored.ID)
		stored.Name = newName
	}
	stored.Description = description
}

func (ps *permissions) Delete(name string) {
	stored := ps.permission(name)
	ps.permissionMap.Remove(stored.ID)
	ps.nameIndex.Remove(stored.Name)
}

func (ps *permissions) Has(name string) bool {
	ps.validateName(name)
	return ps.nameIndex.Has(name)
}

func (ps *permissions) Get(name string) *permission {
	return ps.permission(name)
}

func (ps *permissions) List(page int, count int) []*permission {
	offset := pageOffset(page, count)
	result := make([]*permission, 0, count)
	ps.nameIndex.IterateByOffset(offset, count, func(_ string, idValue any) bool {
		id, ok := idValue.(uint32)
		if !ok {
			panic("invalid permission index")
		}
		result = append(result, ps.permissionByID(id))
		return false
	})
	return result
}

func (ps *permissions) permission(name string) *permission {
	ps.validateName(name)

	idValue, found := ps.nameIndex.Get(name)
	if !found {
		panic("permission not found: " + name)
	}
	id, ok := idValue.(uint32)
	if !ok {
		panic("invalid permission index")
	}
	return ps.permissionByID(id)
}

func (ps *permissions) permissionByID(id uint32) *permission {
	permissionValue, found := ps.permissionMap.Get(id)
	if !found {
		panic("permission not found")
	}
	stored, ok := permissionValue.(*permission)
	if !ok {
		panic("invalid permission")
	}
	return stored
}

func (ps *permissions) nextID() uint32 {
	if ps.idCounter == maxPermissionID {
		panic("permission id exhausted")
	}
	id := ps.idCounter
	ps.idCounter += 1
	return id
}

func (ps *permissions) validateName(name string) {
	if name == "" {
		panic("permission name required")
	}
}
