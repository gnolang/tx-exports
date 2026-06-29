package personal_world

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btree"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btreeset"
)

var worldStore *WorldStore = newWorldStore()

// WorldStore owns personal world records, opaque metadata, and secondary indexes.
//
// Data shape:
// - worlds: worldID(uint32) -> map[string]string
// - metadatas: worldID(uint32) -> metadata(string)
// - slugIndex: slug(string) -> worldID(uint32)
// - nameIndex: name(string) -> worldID(uint32)
// - ownerIndex: owner(address string) -> *Uint32BTreeSet(worldID)
//
// Responsibilities:
// - allocate world IDs and store canonical world records
// - keep slug/name/owner indexes in sync with record mutations
// - store per-world admin-managed opaque metadata text
// - protect store-owned invariants such as duplicate names and slugs
// - return defensive copies from public read methods
//
// Non-responsibilities:
// - validate external parameter shape such as name format, slug format, CSV payloads, or pagination
// - interpret or semantically validate metadata; metadata is off-chain decoded admin text
// - perform auth, payment, freeze, migration, or event handling
// - parse user-facing encoded input; public exported functions must pass canonical values
type WorldStore struct {
	nextWorldID uint32
	worlds      *btree.Uint32BTree
	metadatas   *btree.Uint32BTree
	slugIndex   *btree.StringBTree
	nameIndex   *btree.StringBTree
	ownerIndex  *btree.StringBTree
}

func newWorldStore() *WorldStore {
	return &WorldStore{
		nextWorldID: 1,
		worlds:      btree.NewUint32BTree(32),
		metadatas:   btree.NewUint32BTree(32),
		slugIndex:   btree.NewStringBTree(32),
		nameIndex:   btree.NewStringBTree(32),
		ownerIndex:  btree.NewStringBTree(32),
	}
}

func (s *WorldStore) NextID() uint32 {
	return s.nextWorldID
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *WorldStore) Worlds() *btree.Uint32BTree {
	return s.worlds
}

func (s *WorldStore) Metadatas() *btree.Uint32BTree {
	return s.metadatas
}

func (s *WorldStore) SlugIndex() *btree.StringBTree {
	return s.slugIndex
}

func (s *WorldStore) NameIndex() *btree.StringBTree {
	return s.nameIndex
}

func (s *WorldStore) OwnerIndex() *btree.StringBTree {
	return s.ownerIndex
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *WorldStore) Create(world map[string]string) uint32 {
	name := world["name"]
	slug := world["slug"]
	if s.nameIndex.Has(name) {
		panic("name already exists")
	}
	if s.slugIndex.Has(slug) {
		panic("slug already exists")
	}

	id := s.nextID()
	stored := copyStringMap(world)
	stored["id"] = formatWorldID(id)
	s.worlds.Set(id, stored)
	s.slugIndex.Set(slug, id)
	s.nameIndex.Set(name, id)
	s.addOwnerIndex(id, address(stored["owner"]))
	return id
}

func (s *WorldStore) Update(worldID uint32, updates map[string]string) map[string]string {
	current := s.mustGetInternal(worldID)
	oldOwner := current["owner"]
	newOwner := oldOwner
	if owner, found := updates["owner"]; found {
		newOwner = owner
	}
	oldName := current["name"]
	newName := oldName
	if name, found := updates["name"]; found {
		newName = name
	}
	oldSlug := current["slug"]
	newSlug := oldSlug
	if slug, found := updates["slug"]; found {
		newSlug = slug
	}
	if oldName != newName && s.nameIndex.Has(newName) {
		panic("name already exists")
	}
	if oldSlug != newSlug && s.slugIndex.Has(newSlug) {
		panic("slug already exists")
	}

	updated := copyStringMap(current)
	for key, value := range updates {
		updated[key] = value
	}
	updated["id"] = formatWorldID(worldID)

	if oldOwner != newOwner {
		s.removeOwnerIndex(worldID, address(oldOwner))
		s.addOwnerIndex(worldID, address(newOwner))
	}

	if oldName != newName {
		s.nameIndex.Remove(oldName)
		s.nameIndex.Set(newName, worldID)
	}

	if oldSlug != newSlug {
		s.slugIndex.Remove(oldSlug)
		s.slugIndex.Set(newSlug, worldID)
	}

	s.worlds.Set(worldID, updated)
	return copyStringMap(updated)
}

func (s *WorldStore) Delete(worldID uint32) {
	world := s.mustGetInternal(worldID)
	s.worlds.Remove(worldID)
	s.slugIndex.Remove(world["slug"])
	s.nameIndex.Remove(world["name"])
	s.removeOwnerIndex(worldID, address(world["owner"]))
	s.metadatas.Remove(worldID)
}

func (s *WorldStore) SetMetadata(worldID uint32, metadata string) {
	s.mustGetInternal(worldID)
	s.metadatas.Set(worldID, metadata)
}

func (s *WorldStore) GetMetadata(worldID uint32) string {
	s.mustGetInternal(worldID)
	metadata, found := s.metadatas.Get(worldID)
	if !found {
		return ""
	}
	return metadata.(string)
}

func (s *WorldStore) ListMetadataByIDs(worldIDs ...uint32) []string {
	result := []string{}
	for _, worldID := range worldIDs {
		if !s.worlds.Has(worldID) {
			continue
		}
		metadata, found := s.metadatas.Get(worldID)
		if !found {
			result = append(result, "")
			continue
		}
		result = append(result, metadata.(string))
	}
	return result
}

func (s *WorldStore) MustGet(worldID uint32) map[string]string {
	return copyStringMap(s.mustGetInternal(worldID))
}

func (s *WorldStore) Get(worldID uint32) (map[string]string, bool) {
	world, found := s.worlds.Get(worldID)
	if !found {
		return nil, false
	}
	return copyStringMap(world.(map[string]string)), true
}

func (s *WorldStore) AssertWorldExists(worldID uint32) {
	if !s.worlds.Has(worldID) {
		panic("world not found: " + formatWorldID(worldID))
	}
}

func (s *WorldStore) mustGetInternal(worldID uint32) map[string]string {
	properties, found := s.worlds.Get(worldID)
	if !found {
		panic("world not found: " + formatWorldID(worldID))
	}
	return properties.(map[string]string)
}

func (s *WorldStore) MustGetIDBySlug(slug string) uint32 {
	id, found := s.slugIndex.Get(slug)
	if !found {
		panic("world not found by slug: " + slug)
	}
	return id.(uint32)
}

func (s *WorldStore) MustGetIDByName(name string) uint32 {
	id, found := s.nameIndex.Get(name)
	if !found {
		panic("world not found by name: " + name)
	}
	return id.(uint32)
}

func (s *WorldStore) Total() int {
	return s.worlds.Size()
}

func (s *WorldStore) IsNameAvailable(name string) bool {
	return !s.nameIndex.Has(name)
}

func (s *WorldStore) IsSlugAvailable(slug string) bool {
	return !s.slugIndex.Has(slug)
}

func (s *WorldStore) ListIDs(page int, count int) []uint32 {
	offset := (page - 1) * count
	result := []uint32{}
	s.worlds.IterateByOffset(offset, count, func(worldID uint32, _ any) bool {
		result = append(result, worldID)
		return false
	})
	return result
}

func (s *WorldStore) ListByIDs(worldIDs ...uint32) []map[string]string {
	result := []map[string]string{}
	for _, worldID := range worldIDs {
		world, found := s.Get(worldID)
		if !found {
			continue
		}
		result = append(result, world)
	}
	return result
}

func (s *WorldStore) OwnerCount(owner address) int {
	val, found := s.ownerIndex.Get(owner.String())
	if !found {
		return 0
	}
	return val.(*btreeset.Uint32BTreeSet).Size()
}

func (s *WorldStore) ListIDsByOwner(owner address, page int, count int) []uint32 {
	val, found := s.ownerIndex.Get(owner.String())
	if !found {
		return []uint32{}
	}
	offset := (page - 1) * count
	result := []uint32{}
	val.(*btreeset.Uint32BTreeSet).IterateByOffset(offset, count, func(id uint32) bool {
		result = append(result, id)
		return false
	})
	return result
}

func (s *WorldStore) IsOwner(worldID uint32, user address) bool {
	world := s.mustGetInternal(worldID)
	return address(world["owner"]) == user
}

func (s *WorldStore) nextID() uint32 {
	id := s.nextWorldID
	s.nextWorldID++
	return id
}

func (s *WorldStore) addOwnerIndex(worldID uint32, owner address) {
	ownerKey := owner.String()
	var tree *btreeset.Uint32BTreeSet
	val, found := s.ownerIndex.Get(ownerKey)
	if !found {
		tree = btreeset.NewUint32BTreeSet(16)
		s.ownerIndex.Set(ownerKey, tree)
	} else {
		tree = val.(*btreeset.Uint32BTreeSet)
	}
	tree.Set(worldID)
}

func (s *WorldStore) removeOwnerIndex(worldID uint32, owner address) {
	val, found := s.ownerIndex.Get(owner.String())
	if !found {
		return
	}
	val.(*btreeset.Uint32BTreeSet).Remove(worldID)
}
