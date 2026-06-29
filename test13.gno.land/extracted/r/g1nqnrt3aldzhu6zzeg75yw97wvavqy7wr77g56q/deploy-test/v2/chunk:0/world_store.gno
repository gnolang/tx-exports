package chunk

import "gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btree"

// WorldStore owns chunk world records and secondary indexes.
//
// Data shape:
// - worlds: worldID(uint32) -> map[string]string
// - slugIndex: slug(string) -> worldID(uint32)
// - nameIndex: name(string) -> worldID(uint32)
//
// Responsibilities:
// - store canonical world records by world ID
// - keep slug/name indexes in sync with record mutations
// - protect store-owned invariants such as duplicate world IDs, names, and slugs
// - return defensive copies from public read methods
//
// Non-responsibilities:
// - validate external parameter shape such as slug format, seed range, CSV payloads, or pagination
// - interpret or semantically validate properties; properties are canonical map entries
// - perform auth, freeze, migration, or event handling
// - parse user-facing encoded input; public exported functions must pass canonical values
type WorldStore struct {
	worlds    *btree.Uint32BTree
	slugIndex *btree.StringBTree
	nameIndex *btree.StringBTree
}

var worldStore = newWorldStore()

func newWorldStore() *WorldStore {
	return &WorldStore{
		worlds:    btree.NewUint32BTree(32),
		slugIndex: btree.NewStringBTree(32),
		nameIndex: btree.NewStringBTree(32),
	}
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *WorldStore) Worlds() *btree.Uint32BTree {
	return s.worlds
}

func (s *WorldStore) SlugIndex() *btree.StringBTree {
	return s.slugIndex
}

func (s *WorldStore) NameIndex() *btree.StringBTree {
	return s.nameIndex
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *WorldStore) Create(worldID uint32, world map[string]string) map[string]string {
	name := world["name"]
	slug := world["slug"]
	if _, found := s.worlds.Get(worldID); found {
		panic("world already exists: " + formatWorldID(worldID))
	}
	if s.nameIndex.Has(name) {
		panic("name already exists: " + name)
	}
	if s.slugIndex.Has(slug) {
		panic("slug already exists: " + slug)
	}

	stored := copyStringMap(world)
	stored["id"] = formatWorldID(worldID)
	s.worlds.Set(worldID, stored)
	s.slugIndex.Set(slug, worldID)
	s.nameIndex.Set(name, worldID)
	return copyStringMap(stored)
}

func (s *WorldStore) Update(worldID uint32, updates map[string]string) map[string]string {
	current := s.mustGetInternal(worldID)
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
	renameName := newName != oldName
	renameSlug := newSlug != oldSlug

	if renameName {
		if s.nameIndex.Has(newName) {
			panic("name already exists: " + newName)
		}
	}
	if renameSlug {
		if s.slugIndex.Has(newSlug) {
			panic("slug already exists: " + newSlug)
		}
	}

	updated := copyStringMap(current)
	for key, value := range updates {
		updated[key] = value
	}
	updated["id"] = formatWorldID(worldID)

	if renameName {
		s.nameIndex.Remove(oldName)
		s.nameIndex.Set(newName, worldID)
	}
	if renameSlug {
		s.slugIndex.Remove(oldSlug)
		s.slugIndex.Set(newSlug, worldID)
	}

	s.worlds.Set(worldID, updated)
	return copyStringMap(updated)
}

func (s *WorldStore) MustGet(worldID uint32) map[string]string {
	return copyStringMap(s.mustGetInternal(worldID))
}

func (s *WorldStore) AssertExists(worldID uint32) {
	if !s.worlds.Has(worldID) {
		panic("world not found: " + formatWorldID(worldID))
	}
}

func (s *WorldStore) Has(worldID uint32) bool {
	return s.worlds.Has(worldID)
}

func (s *WorldStore) IsNameAvailable(name string) bool {
	return !s.nameIndex.Has(name)
}

func (s *WorldStore) IsSlugAvailable(slug string) bool {
	return !s.slugIndex.Has(slug)
}

func (s *WorldStore) mustGetInternal(worldID uint32) map[string]string {
	s.AssertExists(worldID)
	value, _ := s.worlds.Get(worldID)
	return value.(map[string]string)
}

func (s *WorldStore) Get(worldID uint32) (map[string]string, bool) {
	value, found := s.worlds.Get(worldID)
	if !found {
		return nil, false
	}
	return copyStringMap(value.(map[string]string)), true
}

func (s *WorldStore) MustGetBySlug(slug string) map[string]string {
	worldID, found := s.slugIndex.Get(slug)
	if !found {
		panic("world not found by slug: " + slug)
	}
	return s.MustGet(worldID.(uint32))
}

func (s *WorldStore) Total() int {
	return s.worlds.Size()
}

func (s *WorldStore) List(page int, count int) []map[string]string {
	offset := (page - 1) * count
	result := []map[string]string{}
	s.worlds.IterateByOffset(offset, count, func(_ uint32, value any) bool {
		result = append(result, copyStringMap(value.(map[string]string)))
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
