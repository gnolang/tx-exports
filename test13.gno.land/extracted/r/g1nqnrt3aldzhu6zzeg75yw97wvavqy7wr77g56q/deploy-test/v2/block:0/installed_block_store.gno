package block

import (
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btree"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/ds/btreeset"
)

var installedBlockStore = newInstalledBlockStore()

// InstalledBlockStore owns installed block indexes, encoded installed payloads,
// encoded use logs, and per-user use log indexes.
//
// Data shape:
// - personalWorldInstalled: storeKey(string) -> *StringBTree(coordKey(string) -> *StringBTree(blockIndexKey(string) -> query-string payload(string)))
// - systemChunkInstalled: storeKey(string) -> *StringBTree(coordKey(string) -> *StringBTree(blockIndexKey(string) -> query-string payload(string)))
// - useLogs: logID(uint64) -> query-string payload(string)
// - userLogIndex: user(address string) -> *Uint64BTreeSet(logID)
//
// Responsibilities:
// - store canonical installed block payloads under position-derived storage keys
// - encode installed block payloads and use logs as query strings
// - allocate use log IDs and maintain per-user use log indexes
// - return fresh maps from public read methods
//
// Non-responsibilities:
// - construct installed block payloads from domain inputs
// - perform auth, payment, freeze, migration, or event handling
type InstalledBlockStore struct {
	personalWorldInstalled *btree.StringBTree
	systemChunkInstalled   *btree.StringBTree
	useLogs                *btree.Uint64BTree
	userLogIndex           *btree.StringBTree
	nextLogID              uint64
}

func newInstalledBlockStore() *InstalledBlockStore {
	return &InstalledBlockStore{
		personalWorldInstalled: btree.NewStringBTree(32),
		systemChunkInstalled:   btree.NewStringBTree(32),
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
func (s *InstalledBlockStore) PersonalWorldInstalled() *btree.StringBTree {
	return s.personalWorldInstalled
}

func (s *InstalledBlockStore) SystemChunkInstalled() *btree.StringBTree {
	return s.systemChunkInstalled
}

func (s *InstalledBlockStore) UseLogs() *btree.Uint64BTree {
	return s.useLogs
}

func (s *InstalledBlockStore) UserLogIndex() *btree.StringBTree {
	return s.userLogIndex
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *InstalledBlockStore) SaveInstalled(positionType string, storeKey string, coordKey string, blockIndexKey string, info map[string]string) map[string]string {
	store := s.storeForPositionType(positionType)
	stored := copyStringMap(info)
	blockTree := s.getOrCreateInstalledBlockTree(store, storeKey, coordKey)
	blockTree.Set(blockIndexKey, encodeStringMap(stored))

	return stored
}

func (s *InstalledBlockStore) RemoveInstalled(positionType string, storeKey string, coordKey string, blockIndexKey string) {
	store := s.storeForPositionType(positionType)
	coordTreeVal, found := store.Get(storeKey)
	if !found {
		return
	}

	coordTree := coordTreeVal.(*btree.StringBTree)
	blockTreeVal, found := coordTree.Get(coordKey)
	if !found {
		return
	}

	blockTree := blockTreeVal.(*btree.StringBTree)
	blockTree.Remove(blockIndexKey)
}

func (s *InstalledBlockStore) GetInstalled(positionType string, storeKey string, coordKey string, blockIndexKey string) (map[string]string, bool) {
	store := s.storeForPositionType(positionType)
	coordTreeVal, found := store.Get(storeKey)
	if !found {
		return nil, false
	}

	coordTree := coordTreeVal.(*btree.StringBTree)
	blockTreeVal, found := coordTree.Get(coordKey)
	if !found {
		return nil, false
	}

	blockTree := blockTreeVal.(*btree.StringBTree)
	infoVal, found := blockTree.Get(blockIndexKey)
	if !found {
		return nil, false
	}

	return decodeStringMap(infoVal.(string)), true
}

func (s *InstalledBlockStore) HasInstalled(positionType string, storeKey string, coordKey string, blockIndexKey string) bool {
	_, found := s.GetInstalled(positionType, storeKey, coordKey, blockIndexKey)
	return found
}

func (s *InstalledBlockStore) appendUseLog(log map[string]string) uint64 {
	logID := s.nextID()
	nextLog := copyStringMap(log)
	nextLog["id"] = logIDToString(logID)
	s.useLogs.Set(logID, encodeStringMap(nextLog))
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

		result = append(result, decodeStringMap(logData.(string)))
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

func (s *InstalledBlockStore) storeForPositionType(positionType string) *btree.StringBTree {
	if positionType == "personal" {
		return s.personalWorldInstalled
	}
	if positionType == "system" {
		return s.systemChunkInstalled
	}
	panic("unknown position type: " + positionType)
}

func (s *InstalledBlockStore) getOrCreateInstalledBlockTree(store *btree.StringBTree, storeKey string, coordKey string) *btree.StringBTree {
	coordTreeVal, found := store.Get(storeKey)
	var coordTree *btree.StringBTree
	if found {
		coordTree = coordTreeVal.(*btree.StringBTree)
	} else {
		coordTree = btree.NewStringBTree(32)
		store.Set(storeKey, coordTree)
	}

	blockTreeVal, found := coordTree.Get(coordKey)
	if found {
		return blockTreeVal.(*btree.StringBTree)
	}

	blockTree := btree.NewStringBTree(32)
	coordTree.Set(coordKey, blockTree)
	return blockTree
}

func (s *InstalledBlockStore) nextID() uint64 {
	id := s.nextLogID
	s.nextLogID++
	return id
}
