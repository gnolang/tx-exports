package block

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/ds/btree"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/ds/btreeset"
	"gno.land/p/nt/bptree/v0"
)

var installedBlockStore = newInstalledBlockStore()

// InstalledBlockStore owns installed block indexes and use log indexes.
//
// Responsibilities:
// - store canonical installed block payloads by position-derived storage keys
// - allocate use log IDs and maintain per-user use log indexes
// - return defensive copies from public read methods
//
// Non-responsibilities:
// - construct installed block payloads from domain inputs
// - perform auth, payment, freeze, migration, or event handling
type InstalledBlockStore struct {
	personalWorldInstalled *bptree.BPTree
	systemChunkInstalled   *bptree.BPTree
	useLogs                *btree.Uint64BTree
	userLogIndex           *btree.StringBTree
	nextLogID              uint64
}

func newInstalledBlockStore() *InstalledBlockStore {
	return &InstalledBlockStore{
		personalWorldInstalled: bptree.NewBPTree32(),
		systemChunkInstalled:   bptree.NewBPTree32(),
		useLogs:                btree.NewUint64BTree(32),
		userLogIndex:           btree.NewStringBTree(32),
		nextLogID:              1,
	}
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *InstalledBlockStore) PersonalWorldInstalled() *bptree.BPTree {
	return s.personalWorldInstalled
}

func (s *InstalledBlockStore) SystemChunkInstalled() *bptree.BPTree {
	return s.systemChunkInstalled
}

func (s *InstalledBlockStore) UseLogs() *btree.Uint64BTree {
	return s.useLogs
}

func (s *InstalledBlockStore) UserLogIndex() *btree.StringBTree {
	return s.userLogIndex
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *InstalledBlockStore) SaveInstalled(position string, info map[string]string) map[string]string {
	store := s.storeForPosition(position)
	storeKey, coordKey, blockIndexKey := parsePosition(position)
	stored := copyStringMap(info)
	blockTree := s.getOrCreateInstalledBlockTree(store, storeKey, coordKey)
	blockTree.Set(blockIndexKey, stored)

	return copyStringMap(stored)
}

func (s *InstalledBlockStore) RemoveInstalled(position string) {
	store := s.storeForPosition(position)
	storeKey, coordKey, blockIndexKey := parsePosition(position)

	coordTreeVal, found := store.Get(storeKey)
	if !found {
		return
	}

	coordTree := coordTreeVal.(*bptree.BPTree)
	blockTreeVal, found := coordTree.Get(coordKey)
	if !found {
		return
	}

	blockTree := blockTreeVal.(*bptree.BPTree)
	blockTree.Remove(blockIndexKey)
}

func (s *InstalledBlockStore) GetInstalled(position string) (map[string]string, bool) {
	store := s.storeForPosition(position)
	storeKey, coordKey, blockIndexKey := parsePosition(position)

	coordTreeVal, found := store.Get(storeKey)
	if !found {
		return nil, false
	}

	coordTree := coordTreeVal.(*bptree.BPTree)
	blockTreeVal, found := coordTree.Get(coordKey)
	if !found {
		return nil, false
	}

	blockTree := blockTreeVal.(*bptree.BPTree)
	infoVal, found := blockTree.Get(blockIndexKey)
	if !found {
		return nil, false
	}

	return copyStringMap(infoVal.(map[string]string)), true
}

func (s *InstalledBlockStore) HasInstalled(position string) bool {
	_, found := s.GetInstalled(position)
	return found
}

func (s *InstalledBlockStore) ListInstalled(positions ...string) []map[string]string {
	result := []map[string]string{}
	for _, position := range positions {
		if info, found := s.GetInstalled(position); found {
			result = append(result, info)
		}
	}
	return result
}

func (s *InstalledBlockStore) appendUseLog(log map[string]string) uint64 {
	logID := s.nextID()
	nextLog := copyStringMap(log)
	nextLog["id"] = logIDToString(logID)
	s.useLogs.Set(logID, nextLog)
	return logID
}

func (s *InstalledBlockStore) RecordUse(user address, result map[string]string) map[string]string {
	if result["id"] != "" {
		panic("use result already recorded")
	}

	logID := s.appendUseLog(result)
	s.addUserLogIndex(user, logID)

	recorded := copyStringMap(result)
	recorded["id"] = logIDToString(logID)
	return recorded
}

func (s *InstalledBlockStore) addUserLogIndex(user address, logID uint64) {
	userStr := user.String()
	logs, found := s.userLogIndex.Get(userStr)

	var logIDs *btreeset.Uint64BTreeSet
	if found {
		logIDs = logs.(*btreeset.Uint64BTreeSet)
	} else {
		logIDs = btreeset.NewUint64BTreeSet(32)
		s.userLogIndex.Set(userStr, logIDs)
	}

	logIDs.Set(logID)
}

func (s *InstalledBlockStore) ListUseLogs(user address, limit int) []map[string]string {
	result := []map[string]string{}
	if limit <= 0 {
		return result
	}

	logs, found := s.userLogIndex.Get(user.String())
	if !found {
		return result
	}

	count := 0
	logIDs := logs.(*btreeset.Uint64BTreeSet)
	logIDs.ReverseIterate(nil, nil, func(logID uint64) bool {
		if count >= limit {
			return true
		}

		logData, found := s.useLogs.Get(logID)
		if !found {
			return false
		}

		result = append(result, copyStringMap(logData.(map[string]string)))
		count++
		return false
	})
	return result
}

func (s *InstalledBlockStore) NextLogID() uint64 {
	return s.nextLogID
}

func (s *InstalledBlockStore) UseLogTotal() int {
	return s.useLogs.Size()
}

func (s *InstalledBlockStore) UserLogIndexTotal() int {
	return s.userLogIndex.Size()
}

func (s *InstalledBlockStore) PersonalInstalledTotal() int {
	return s.personalWorldInstalled.Size()
}

func (s *InstalledBlockStore) SystemInstalledTotal() int {
	return s.systemChunkInstalled.Size()
}

func (s *InstalledBlockStore) storeForPosition(position string) *bptree.BPTree {
	if isPersonalWorld(position) {
		return s.personalWorldInstalled
	}
	if isSystemChunk(position) {
		return s.systemChunkInstalled
	}
	panic("unknown position type: " + position)
}

func (s *InstalledBlockStore) getOrCreateInstalledBlockTree(store *bptree.BPTree, storeKey string, coordKey string) *bptree.BPTree {
	coordTreeVal, found := store.Get(storeKey)
	var coordTree *bptree.BPTree
	if found {
		coordTree = coordTreeVal.(*bptree.BPTree)
	} else {
		coordTree = bptree.NewBPTree32()
		store.Set(storeKey, coordTree)
	}

	blockTreeVal, found := coordTree.Get(coordKey)
	if found {
		return blockTreeVal.(*bptree.BPTree)
	}

	blockTree := bptree.NewBPTree32()
	coordTree.Set(coordKey, blockTree)
	return blockTree
}

func (s *InstalledBlockStore) nextID() uint64 {
	id := s.nextLogID
	s.nextLogID++
	return id
}
