package rbac

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btree"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btreeset"
)

type grants struct {
	degree     int
	grantIndex *btree.Uint32BTree
}

func newGrants(degree int) *grants {
	return &grants{
		degree:     degree,
		grantIndex: btree.NewUint32BTree(degree),
	}
}

func (gs *grants) Add(granterRoleID uint32, granteeRoleID uint32) {
	grantees := gs.getOrCreateGranteeSet(granterRoleID)
	if grantees.Has(granteeRoleID) {
		panic("grant already exists: granterRoleID=" + formatRoleID(granterRoleID) + ", granteeRoleID=" + formatRoleID(granteeRoleID))
	}
	grantees.Set(granteeRoleID)
}

func (gs *grants) Delete(granterRoleID uint32, granteeRoleID uint32) {
	grantees, found := gs.findGranteeSet(granterRoleID)
	if !found || !grantees.Has(granteeRoleID) {
		panic("grant not found: granterRoleID=" + formatRoleID(granterRoleID) + ", granteeRoleID=" + formatRoleID(granteeRoleID))
	}
	grantees.Remove(granteeRoleID)
	if grantees.Size() == 0 {
		gs.grantIndex.Remove(granterRoleID)
	}
}

func (gs *grants) Has(granterRoleID uint32, granteeRoleID uint32) bool {
	grantees, found := gs.findGranteeSet(granterRoleID)
	if !found {
		return false
	}
	return grantees.Has(granteeRoleID)
}

func (gs *grants) DeleteRole(roleID uint32) {
	gs.grantIndex.Remove(roleID)

	emptyGranters := []uint32{}
	gs.grantIndex.Iterate(nil, nil, func(granterRoleID uint32, granteesValue any) bool {
		grantees := castGranteeSet(granterRoleID, granteesValue)
		grantees.Remove(roleID)
		if grantees.Size() == 0 {
			emptyGranters = append(emptyGranters, granterRoleID)
		}
		return false
	})
	for _, granterRoleID := range emptyGranters {
		gs.grantIndex.Remove(granterRoleID)
	}
}

func (gs *grants) ListGrantees(granterRoleID uint32, page int, count int) []uint32 {
	offset := pageOffset(page, count)

	grantees, found := gs.findGranteeSet(granterRoleID)
	if !found {
		return []uint32{}
	}

	result := make([]uint32, 0, count)
	grantees.IterateByOffset(offset, count, func(granteeRoleID uint32) bool {
		result = append(result, granteeRoleID)
		return false
	})
	return result
}

func (gs *grants) Size() int {
	size := 0
	gs.grantIndex.Iterate(nil, nil, func(granterRoleID uint32, granteesValue any) bool {
		size += castGranteeSet(granterRoleID, granteesValue).Size()
		return false
	})
	return size
}

func (gs *grants) GranteeSize(granterRoleID uint32) int {
	grantees, found := gs.findGranteeSet(granterRoleID)
	if !found {
		return 0
	}
	return grantees.Size()
}

func (gs *grants) findGranteeSet(granterRoleID uint32) (*btreeset.Uint32BTreeSet, bool) {
	granteesValue, found := gs.grantIndex.Get(granterRoleID)
	if !found {
		return nil, false
	}
	return castGranteeSet(granterRoleID, granteesValue), true
}

func (gs *grants) getOrCreateGranteeSet(granterRoleID uint32) *btreeset.Uint32BTreeSet {
	grantees, found := gs.findGranteeSet(granterRoleID)
	if found {
		return grantees
	}

	grantees = btreeset.NewUint32BTreeSet(gs.degree)
	gs.grantIndex.Set(granterRoleID, grantees)
	return grantees
}

func castGranteeSet(granterRoleID uint32, granteesValue any) *btreeset.Uint32BTreeSet {
	grantees, ok := granteesValue.(*btreeset.Uint32BTreeSet)
	if !ok {
		panic("invalid grant index: " + formatRoleID(granterRoleID))
	}
	return grantees
}
