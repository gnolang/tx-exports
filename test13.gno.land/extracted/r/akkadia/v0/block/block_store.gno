package block

import "gno.land/p/akkadia/v0/ds/btree"

const defaultSystemBlockLimit uint32 = 100000

var blockStore = newBlockStore()

// BlockStore owns block records and secondary indexes.
//
// Data shape:
// - records: blockID(uint32) -> query-string payload(string)
// - nameIndex: name(string) -> blockID(uint32)
// - metadatas: blockID(uint32) -> metadata(string)
// - acrRewardAllowlist: blockID(uint32) -> bool
//
// Responsibilities:
// - allocate normal block IDs and store canonical block records by block ID
// - keep block name indexes and ACR reward allowlists in sync with record mutations
// - protect store-owned invariants such as duplicate block IDs and names
// - return defensive copies from public read methods
//
// Non-responsibilities:
// - validate external parameter shape such as block name format, supply range, or pagination
// - parse user-facing encoded input such as CSV property payloads
// - perform auth, freeze, migration, payment, or event handling
// - interpret economics beyond store-owned existence and index consistency
type BlockStore struct {
	records            *btree.Uint32BTree
	nameIndex          *btree.StringBTree
	metadatas          *btree.Uint32BTree
	acrRewardAllowlist *btree.Uint32BTree
	systemBlockLimit   uint32
	maxSystemBlockID   uint32
	nextBlockID        uint32
}

func newBlockStore() *BlockStore {
	return &BlockStore{
		records:            btree.NewUint32BTree(32),
		nameIndex:          btree.NewStringBTree(32),
		metadatas:          btree.NewUint32BTree(32),
		acrRewardAllowlist: btree.NewUint32BTree(32),
		systemBlockLimit:   defaultSystemBlockLimit,
		maxSystemBlockID:   0,
		nextBlockID:        defaultSystemBlockLimit,
	}
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *BlockStore) Records() *btree.Uint32BTree {
	return s.records
}

func (s *BlockStore) NameIndex() *btree.StringBTree {
	return s.nameIndex
}

func (s *BlockStore) AcrRewardAllowlist() *btree.Uint32BTree {
	return s.acrRewardAllowlist
}

func (s *BlockStore) Metadatas() *btree.Uint32BTree {
	return s.metadatas
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *BlockStore) Create(record map[string]string) uint32 {
	name := record["name"]
	if s.nameIndex.Has(name) {
		panic("name already exists: " + name)
	}

	blockID := s.nextID()
	s.set(blockID, record)
	return blockID
}

func (s *BlockStore) CreateSystem(blockID uint32, record map[string]string) {
	name := record["name"]
	blockIDStr := blockIDToString(blockID)
	if !s.IsSystemID(blockID) {
		panic("block ID must be less than 100000")
	}
	if _, found := s.records.Get(blockID); found {
		panic("block already exists: " + blockIDStr)
	}
	if s.nameIndex.Has(name) {
		panic("name already exists: " + name)
	}

	if s.maxSystemBlockID < blockID {
		s.maxSystemBlockID = blockID
	}

	s.set(blockID, record)
}

func (s *BlockStore) Delete(blockID uint32) {
	block := s.MustGet(blockID)
	s.nameIndex.Remove(block["name"])
	s.records.Remove(blockID)
	s.metadatas.Remove(blockID)
	s.acrRewardAllowlist.Remove(blockID)
}

func (s *BlockStore) Update(blockID uint32, updates map[string]string) map[string]string {
	current := s.mustGetDecoded(blockID)
	oldName := current["name"]
	newName := oldName
	if name, found := updates["name"]; found {
		newName = name
	}
	if oldName != newName {
		if s.nameIndex.Has(newName) {
			panic("name already exists: " + newName)
		}
	}

	updated := copyStringMap(current)
	for key, val := range updates {
		updated[key] = val
	}
	updated["id"] = blockIDToString(blockID)

	if oldName != newName {
		s.nameIndex.Remove(oldName)
		s.nameIndex.Set(newName, blockID)
	}

	s.records.Set(blockID, encodeStringMap(updated))
	return copyStringMap(updated)
}

func (s *BlockStore) Has(blockID uint32) bool {
	return s.records.Has(blockID)
}

func (s *BlockStore) Get(blockID uint32) (map[string]string, bool) {
	blockVal, found := s.records.Get(blockID)
	if !found {
		return nil, false
	}
	return decodeStringMap(blockVal.(string)), true
}

func (s *BlockStore) MustGet(blockID uint32) map[string]string {
	return s.mustGetDecoded(blockID)
}

func (s *BlockStore) mustGetDecoded(blockID uint32) map[string]string {
	blockVal, found := s.records.Get(blockID)
	if !found {
		panic("block not found: " + blockIDToString(blockID))
	}
	return decodeStringMap(blockVal.(string))
}

func (s *BlockStore) mustHave(blockID uint32) {
	if !s.records.Has(blockID) {
		panic("block not found: " + blockIDToString(blockID))
	}
}

func (s *BlockStore) MustGetByName(name string) map[string]string {
	blockIDVal, found := s.nameIndex.Get(name)
	if !found {
		panic("block not found by name: " + name)
	}
	return s.MustGet(blockIDVal.(uint32))
}

func (s *BlockStore) List(page, count int) []map[string]string {
	result := []map[string]string{}
	offset := (page - 1) * count
	s.records.IterateByOffset(offset, count, func(_ uint32, value interface{}) bool {
		result = append(result, decodeStringMap(value.(string)))
		return false
	})
	return result
}

func (s *BlockStore) ListFromTo(from, to *uint32, limit uint32) []map[string]string {
	result := []map[string]string{}
	if limit == 0 {
		return result
	}

	if from != nil && to != nil && *from > *to {
		panic("from is greater than to")
	}

	var end *uint32
	if to != nil && *to < ^uint32(0) {
		endValue := *to + 1
		end = &endValue
	}
	s.records.Iterate(from, end, func(_ uint32, value any) bool {
		result = append(result, decodeStringMap(value.(string)))
		return len(result) >= int(limit)
	})
	return result
}

func (s *BlockStore) ListByIDs(blockIDs ...uint32) []map[string]string {
	result := []map[string]string{}
	for _, blockID := range blockIDs {
		block, found := s.Get(blockID)
		if found {
			result = append(result, block)
		}
	}
	return result
}

func (s *BlockStore) SetMetadata(blockID uint32, metadata string) {
	s.mustHave(blockID)
	s.metadatas.Set(blockID, metadata)
}

func (s *BlockStore) GetBlockMetadata(blockID uint32) string {
	s.mustHave(blockID)
	metadata, found := s.metadatas.Get(blockID)
	if !found {
		return ""
	}
	return metadata.(string)
}

func (s *BlockStore) ListBlockMetadataByIDs(blockIDs ...uint32) []string {
	result := []string{}
	for _, blockID := range blockIDs {
		if !s.records.Has(blockID) {
			continue
		}
		metadata, found := s.metadatas.Get(blockID)
		if !found {
			result = append(result, "")
			continue
		}
		result = append(result, metadata.(string))
	}
	return result
}

func (s *BlockStore) Total() int {
	return s.records.Size()
}

func (s *BlockStore) NameIndexTotal() int {
	return s.nameIndex.Size()
}

func (s *BlockStore) SetAcrRewardEnabled(blockID uint32) {
	if !s.Has(blockID) {
		panic("block not found: " + blockIDToString(blockID))
	}
	s.acrRewardAllowlist.Set(blockID, true)
}

func (s *BlockStore) UnsetAcrRewardEnabled(blockID uint32) {
	blockIDStr := blockIDToString(blockID)
	if !s.acrRewardAllowlist.Has(blockID) {
		panic("block not in acr reward allowlist: " + blockIDStr)
	}
	s.acrRewardAllowlist.Remove(blockID)
}

func (s *BlockStore) IsAcrRewardEnabled(blockID uint32) bool {
	return s.acrRewardAllowlist.Has(blockID)
}

func (s *BlockStore) ListAcrRewardEnabled() []string {
	result := []string{}
	s.acrRewardAllowlist.Iterate(nil, nil, func(key uint32, value any) bool {
		result = append(result, blockIDToString(key))
		return false
	})
	return result
}

func (s *BlockStore) AcrRewardTotal() int {
	return s.acrRewardAllowlist.Size()
}

func (s *BlockStore) SystemTotal() int {
	result := 0
	for i := uint32(0); i <= s.maxSystemBlockID; i++ {
		if s.records.Has(i) {
			result++
		}
	}
	return result
}

func (s *BlockStore) NormalTotal() int {
	return s.Total() - s.SystemTotal()
}

func (s *BlockStore) NextID() uint32 {
	return s.nextBlockID
}

func (s *BlockStore) SystemBlockLimit() uint32 {
	return s.systemBlockLimit
}

func (s *BlockStore) MaxSystemBlockID() uint32 {
	return s.maxSystemBlockID
}

func (s *BlockStore) IsSystemID(blockID uint32) bool {
	return blockID < s.systemBlockLimit
}

func (s *BlockStore) nextID() uint32 {
	id := s.nextBlockID
	s.nextBlockID++
	return id
}

func (s *BlockStore) set(blockID uint32, record map[string]string) {
	stored := copyStringMap(record)
	stored["id"] = blockIDToString(blockID)
	s.records.Set(blockID, encodeStringMap(stored))
	s.nameIndex.Set(stored["name"], blockID)
}
