package blueprint

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btree"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btreeset"
)

var blueprintStore *BlueprintStore = newBlueprintStore()

// BlueprintStore owns blueprint records, opaque metadata, and secondary indexes.
//
// Data shape:
// - blueprints: blueprintID(uint32) -> map[string]string
// - metadatas: blueprintID(uint32) -> metadata(string)
// - nameIndex: name(string) -> blueprintID(uint32)
// - ownerIndex: owner(address string) -> *Uint32BTreeSet(blueprintID)
// - biomeIndex: biome(string) -> *Uint32BTreeSet(blueprintID)
// - stateIndex: state(string) -> *Uint32BTreeSet(blueprintID)
// - biomeStateIndex: biome(string) -> *StringBTree(state(string) -> *Uint32BTreeSet(blueprintID))
//
// Responsibilities:
// - allocate blueprint IDs and store canonical blueprint records
// - keep name/owner/biome/state/biome-state indexes in sync with record mutations
// - store per-blueprint admin-managed opaque metadata text
// - protect store-owned invariants such as duplicate names
// - return defensive copies from public read methods
//
// Non-responsibilities:
// - validate external parameter shape such as name format, CSV payloads, or pagination
// - interpret or semantically validate metadata; metadata is off-chain decoded admin text
// - perform auth, payment, freeze, migration, or event handling
// - parse user-facing encoded input; public exported functions must pass canonical values
type BlueprintStore struct {
	nextBlueprintID uint32
	blueprints      *btree.Uint32BTree
	metadatas       *btree.Uint32BTree
	nameIndex       *btree.StringBTree
	ownerIndex      *btree.StringBTree
	biomeIndex      *btree.StringBTree
	stateIndex      *btree.StringBTree
	biomeStateIndex *btree.StringBTree
}

func newBlueprintStore() *BlueprintStore {
	return &BlueprintStore{
		nextBlueprintID: 1,
		blueprints:      btree.NewUint32BTree(32),
		metadatas:       btree.NewUint32BTree(32),
		nameIndex:       btree.NewStringBTree(32),
		ownerIndex:      btree.NewStringBTree(32),
		biomeIndex:      btree.NewStringBTree(32),
		stateIndex:      btree.NewStringBTree(32),
		biomeStateIndex: btree.NewStringBTree(32),
	}
}

func (s *BlueprintStore) NextID() uint32 {
	return s.nextBlueprintID
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *BlueprintStore) Blueprints() *btree.Uint32BTree {
	return s.blueprints
}

func (s *BlueprintStore) Metadatas() *btree.Uint32BTree {
	return s.metadatas
}

func (s *BlueprintStore) NameIndex() *btree.StringBTree {
	return s.nameIndex
}

func (s *BlueprintStore) OwnerIndex() *btree.StringBTree {
	return s.ownerIndex
}

func (s *BlueprintStore) BiomeIndex() *btree.StringBTree {
	return s.biomeIndex
}

func (s *BlueprintStore) StateIndex() *btree.StringBTree {
	return s.stateIndex
}

func (s *BlueprintStore) BiomeStateIndex() *btree.StringBTree {
	return s.biomeStateIndex
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *BlueprintStore) Create(blueprint map[string]string) uint32 {
	name := blueprint["name"]
	if s.nameIndex.Has(name) {
		panic("name already exists")
	}

	id := s.nextID()
	stored := copyStringMap(blueprint)
	stored["id"] = formatBlueprintID(id)
	s.blueprints.Set(id, stored)
	s.nameIndex.Set(name, id)
	s.addOwnerIndex(id, address(stored["owner"]))
	s.addBiomeIndex(id, stored["biome"])
	s.addStateIndex(id, stored["state"])
	s.addBiomeStateIndex(id, stored["biome"], stored["state"])
	return id
}

func (s *BlueprintStore) Update(blueprintID uint32, updates map[string]string) map[string]string {
	current := s.mustGetInternal(blueprintID)
	oldName := current["name"]
	if name, found := updates["name"]; found {
		if oldName != name && s.nameIndex.Has(name) {
			panic("name already exists")
		}
	}

	updated := copyStringMap(current)
	for key, value := range updates {
		updated[key] = value
	}
	updated["id"] = formatBlueprintID(blueprintID)

	oldOwner := current["owner"]
	newOwner := updated["owner"]
	newName := updated["name"]
	oldBiome := current["biome"]
	newBiome := updated["biome"]
	oldState := current["state"]
	newState := updated["state"]

	if oldOwner != newOwner {
		s.removeOwnerIndex(blueprintID, address(oldOwner))
		s.addOwnerIndex(blueprintID, address(newOwner))
	}
	if oldName != newName {
		s.nameIndex.Remove(oldName)
		s.nameIndex.Set(newName, blueprintID)
	}
	if oldBiome != newBiome {
		s.removeBiomeIndex(blueprintID, oldBiome)
		s.addBiomeIndex(blueprintID, newBiome)
	}
	if oldState != newState {
		s.removeStateIndex(blueprintID, oldState)
		s.addStateIndex(blueprintID, newState)
	}
	if oldBiome != newBiome || oldState != newState {
		s.removeBiomeStateIndex(blueprintID, oldBiome, oldState)
		s.addBiomeStateIndex(blueprintID, newBiome, newState)
	}

	s.blueprints.Set(blueprintID, updated)
	return copyStringMap(updated)
}

func (s *BlueprintStore) Delete(blueprintID uint32) {
	blueprint := s.mustGetInternal(blueprintID)
	s.blueprints.Remove(blueprintID)
	s.nameIndex.Remove(blueprint["name"])
	s.removeOwnerIndex(blueprintID, address(blueprint["owner"]))
	s.removeBiomeIndex(blueprintID, blueprint["biome"])
	s.removeStateIndex(blueprintID, blueprint["state"])
	s.removeBiomeStateIndex(blueprintID, blueprint["biome"], blueprint["state"])
	s.metadatas.Remove(blueprintID)
}

func (s *BlueprintStore) SetMetadata(blueprintID uint32, metadata string) {
	s.mustGetInternal(blueprintID)
	s.metadatas.Set(blueprintID, metadata)
}

func (s *BlueprintStore) GetMetadata(blueprintID uint32) string {
	s.mustGetInternal(blueprintID)
	metadata, found := s.metadatas.Get(blueprintID)
	if !found {
		return ""
	}
	return metadata.(string)
}

func (s *BlueprintStore) ListMetadataByIDs(blueprintIDs ...uint32) []string {
	result := []string{}
	for _, blueprintID := range blueprintIDs {
		if !s.blueprints.Has(blueprintID) {
			continue
		}
		metadata, found := s.metadatas.Get(blueprintID)
		if !found {
			result = append(result, "")
			continue
		}
		result = append(result, metadata.(string))
	}
	return result
}

func (s *BlueprintStore) MustGet(blueprintID uint32) map[string]string {
	return copyStringMap(s.mustGetInternal(blueprintID))
}

func (s *BlueprintStore) Get(blueprintID uint32) (map[string]string, bool) {
	blueprint, found := s.blueprints.Get(blueprintID)
	if !found {
		return nil, false
	}
	return copyStringMap(blueprint.(map[string]string)), true
}

func (s *BlueprintStore) AssertBlueprintExists(blueprintID uint32) {
	if !s.blueprints.Has(blueprintID) {
		panic("blueprint not found: " + formatBlueprintID(blueprintID))
	}
}

func (s *BlueprintStore) mustGetInternal(blueprintID uint32) map[string]string {
	properties, found := s.blueprints.Get(blueprintID)
	if !found {
		panic("blueprint not found: " + formatBlueprintID(blueprintID))
	}
	return properties.(map[string]string)
}

func (s *BlueprintStore) MustGetIDByName(name string) uint32 {
	id, found := s.nameIndex.Get(name)
	if !found {
		panic("blueprint not found by name: " + name)
	}
	return id.(uint32)
}

func (s *BlueprintStore) Total() int {
	return s.blueprints.Size()
}

func (s *BlueprintStore) IsNameAvailable(name string) bool {
	return !s.nameIndex.Has(name)
}

func (s *BlueprintStore) ListIDs(page int, count int) []uint32 {
	offset := (page - 1) * count
	result := []uint32{}
	s.blueprints.IterateByOffset(offset, count, func(blueprintID uint32, _ any) bool {
		result = append(result, blueprintID)
		return false
	})
	return result
}

func (s *BlueprintStore) ListByIDs(blueprintIDs ...uint32) []map[string]string {
	result := []map[string]string{}
	for _, blueprintID := range blueprintIDs {
		blueprint, found := s.Get(blueprintID)
		if !found {
			continue
		}
		result = append(result, blueprint)
	}
	return result
}

func (s *BlueprintStore) OwnerCount(owner address) int {
	val, found := s.ownerIndex.Get(owner.String())
	if !found {
		return 0
	}
	return val.(*btreeset.Uint32BTreeSet).Size()
}

func (s *BlueprintStore) ListIDsByOwner(owner address, page int, count int) []uint32 {
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

func (s *BlueprintStore) BiomeCount(biomeName string) int {
	val, found := s.biomeIndex.Get(biomeName)
	if !found {
		return 0
	}
	return val.(*btreeset.Uint32BTreeSet).Size()
}

func (s *BlueprintStore) ListIDsByBiome(biomeName string, page int, count int) []uint32 {
	val, found := s.biomeIndex.Get(biomeName)
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

func (s *BlueprintStore) StateCount(state string) int {
	val, found := s.stateIndex.Get(state)
	if !found {
		return 0
	}
	return val.(*btreeset.Uint32BTreeSet).Size()
}

func (s *BlueprintStore) ListIDsByState(state string, page int, count int) []uint32 {
	val, found := s.stateIndex.Get(state)
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

func (s *BlueprintStore) BiomeStateCount(biomeName string, state string) int {
	stateTree, found := s.biomeStateTree(biomeName)
	if !found {
		return 0
	}
	val, found := stateTree.Get(state)
	if !found {
		return 0
	}
	return val.(*btreeset.Uint32BTreeSet).Size()
}

func (s *BlueprintStore) ListIDsByBiomeState(biomeName string, state string, page int, count int) []uint32 {
	stateTree, found := s.biomeStateTree(biomeName)
	if !found {
		return []uint32{}
	}
	val, found := stateTree.Get(state)
	if !found {
		return []uint32{}
	}

	offset := (page - 1) * count
	result := []uint32{}
	val.(*btreeset.Uint32BTreeSet).IterateByOffset(offset, count, func(blueprintID uint32) bool {
		result = append(result, blueprintID)
		return false
	})
	return result
}

func (s *BlueprintStore) IsOwner(blueprintID uint32, user address) bool {
	blueprint := s.mustGetInternal(blueprintID)
	return address(blueprint["owner"]) == user
}

func (s *BlueprintStore) nextID() uint32 {
	id := s.nextBlueprintID
	s.nextBlueprintID++
	return id
}

func (s *BlueprintStore) addOwnerIndex(blueprintID uint32, owner address) {
	ownerKey := owner.String()
	var tree *btreeset.Uint32BTreeSet
	val, found := s.ownerIndex.Get(ownerKey)
	if !found {
		tree = btreeset.NewUint32BTreeSet(16)
		s.ownerIndex.Set(ownerKey, tree)
	} else {
		tree = val.(*btreeset.Uint32BTreeSet)
	}
	tree.Set(blueprintID)
}

func (s *BlueprintStore) removeOwnerIndex(blueprintID uint32, owner address) {
	val, found := s.ownerIndex.Get(owner.String())
	if !found {
		return
	}
	val.(*btreeset.Uint32BTreeSet).Remove(blueprintID)
}

func (s *BlueprintStore) addBiomeIndex(blueprintID uint32, biomeName string) {
	var tree *btreeset.Uint32BTreeSet
	val, found := s.biomeIndex.Get(biomeName)
	if !found {
		tree = btreeset.NewUint32BTreeSet(16)
		s.biomeIndex.Set(biomeName, tree)
	} else {
		tree = val.(*btreeset.Uint32BTreeSet)
	}
	tree.Set(blueprintID)
}

func (s *BlueprintStore) removeBiomeIndex(blueprintID uint32, biomeName string) {
	val, found := s.biomeIndex.Get(biomeName)
	if !found {
		return
	}
	val.(*btreeset.Uint32BTreeSet).Remove(blueprintID)
}

func (s *BlueprintStore) addStateIndex(blueprintID uint32, state string) {
	var tree *btreeset.Uint32BTreeSet
	val, found := s.stateIndex.Get(state)
	if !found {
		tree = btreeset.NewUint32BTreeSet(16)
		s.stateIndex.Set(state, tree)
	} else {
		tree = val.(*btreeset.Uint32BTreeSet)
	}
	tree.Set(blueprintID)
}

func (s *BlueprintStore) removeStateIndex(blueprintID uint32, state string) {
	val, found := s.stateIndex.Get(state)
	if !found {
		return
	}
	val.(*btreeset.Uint32BTreeSet).Remove(blueprintID)
}

func (s *BlueprintStore) addBiomeStateIndex(blueprintID uint32, biomeName string, state string) {
	stateTree := s.getOrCreateBiomeStateTree(biomeName)

	var set *btreeset.Uint32BTreeSet
	val, found := stateTree.Get(state)
	if !found {
		set = btreeset.NewUint32BTreeSet(16)
		stateTree.Set(state, set)
	} else {
		set = val.(*btreeset.Uint32BTreeSet)
	}
	set.Set(blueprintID)
}

func (s *BlueprintStore) removeBiomeStateIndex(blueprintID uint32, biomeName string, state string) {
	stateTree, found := s.biomeStateTree(biomeName)
	if !found {
		return
	}
	val, found := stateTree.Get(state)
	if !found {
		return
	}
	val.(*btreeset.Uint32BTreeSet).Remove(blueprintID)
}

func (s *BlueprintStore) biomeStateTree(biomeName string) (*btree.StringBTree, bool) {
	val, found := s.biomeStateIndex.Get(biomeName)
	if !found {
		return nil, false
	}
	return val.(*btree.StringBTree), true
}

func (s *BlueprintStore) getOrCreateBiomeStateTree(biomeName string) *btree.StringBTree {
	tree, found := s.biomeStateTree(biomeName)
	if found {
		return tree
	}
	tree = btree.NewStringBTree(16)
	s.biomeStateIndex.Set(biomeName, tree)
	return tree
}
