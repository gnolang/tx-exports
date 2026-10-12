package game_vault

import (
	"strconv"

	"gno.land/p/nt/bptree/v0"
)

var (
	rewardPools                      *bptree.BPTree
	rewardPoolIDs                    *bptree.BPTree
	gameWorldRewardPoolIDs           *bptree.BPTree
	participationProcesses           *bptree.BPTree
	participationProcessIDs          *bptree.BPTree
	gameWorldParticipationProcessIDs *bptree.BPTree
	participationFunds               *bptree.BPTree
	participationFundIDs             *bptree.BPTree
	participationOwnerFundIDs        *bptree.BPTree
	participationGroupFundIDs        *bptree.BPTree
	entryProcesses                   *bptree.BPTree
	entryProcessIDs                  *bptree.BPTree
	gameWorldEntryProcessIDs         *bptree.BPTree
	entryFunds                       *bptree.BPTree
	entryFundIDs                     *bptree.BPTree
	entryOwnerFundIDs                *bptree.BPTree
	entryGroupFundIDs                *bptree.BPTree
	systemFundings                   *bptree.BPTree
	systemFundingIDs                 *bptree.BPTree
	poolSystemFundingIDs             *bptree.BPTree
	rewardDistributions              *bptree.BPTree
	rewardDistributionIDs            *bptree.BPTree
	poolDistributionIDs              *bptree.BPTree
	vaultRefunds                     *bptree.BPTree
	vaultRefundIDs                   *bptree.BPTree
	poolRefundIDs                    *bptree.BPTree
	processedOperationKeys           *bptree.BPTree
	latestRewardPoolID               uint64
	latestParticipationProcessID     uint64
	latestParticipationFundID        uint64
	latestEntryProcessID             uint64
	latestEntryFundID                uint64
	latestSystemFundingID            uint64
	latestRewardDistributionID       uint64
	latestVaultRefundID              uint64
	accountedUgnotTotal              int64
)

func init() {
	resetGameVaultState()
}

func resetGameVaultState() {
	rewardPools = bptree.NewBPTree32()
	rewardPoolIDs = bptree.NewBPTree32()
	gameWorldRewardPoolIDs = bptree.NewBPTree32()
	participationProcesses = bptree.NewBPTree32()
	participationProcessIDs = bptree.NewBPTree32()
	gameWorldParticipationProcessIDs = bptree.NewBPTree32()
	participationFunds = bptree.NewBPTree32()
	participationFundIDs = bptree.NewBPTree32()
	participationOwnerFundIDs = bptree.NewBPTree32()
	participationGroupFundIDs = bptree.NewBPTree32()
	entryProcesses = bptree.NewBPTree32()
	entryProcessIDs = bptree.NewBPTree32()
	gameWorldEntryProcessIDs = bptree.NewBPTree32()
	entryFunds = bptree.NewBPTree32()
	entryFundIDs = bptree.NewBPTree32()
	entryOwnerFundIDs = bptree.NewBPTree32()
	entryGroupFundIDs = bptree.NewBPTree32()
	systemFundings = bptree.NewBPTree32()
	systemFundingIDs = bptree.NewBPTree32()
	poolSystemFundingIDs = bptree.NewBPTree32()
	rewardDistributions = bptree.NewBPTree32()
	rewardDistributionIDs = bptree.NewBPTree32()
	poolDistributionIDs = bptree.NewBPTree32()
	vaultRefunds = bptree.NewBPTree32()
	vaultRefundIDs = bptree.NewBPTree32()
	poolRefundIDs = bptree.NewBPTree32()
	processedOperationKeys = bptree.NewBPTree32()
	latestRewardPoolID = 0
	latestParticipationProcessID = 0
	latestParticipationFundID = 0
	latestEntryProcessID = 0
	latestEntryFundID = 0
	latestSystemFundingID = 0
	latestRewardDistributionID = 0
	latestVaultRefundID = 0
	accountedUgnotTotal = 0
	distributionBatchMax = distributionBatchMaxDefault
}

func ownerKey(processID uint64, owner address) string {
	return strconv.FormatUint(processID, 10) + ":" + owner.String()
}

func keyedOwnerKey(processID uint64, owner address, key string) string {
	return ownerKey(processID, owner) + ":" + key
}

func uint64Key(id uint64) string {
	// Zero-pad so BPTree key order matches numeric ID order.
	s := strconv.FormatUint(id, 10)
	if len(s) >= 20 {
		return s
	}
	return "00000000000000000000"[len(s):] + s
}

func parseUint64Key(key string) uint64 {
	id, err := strconv.ParseUint(key, 10, 64)
	if err != nil {
		panic("invalid uint64 key: " + key)
	}
	return id
}

func treeGet(store *bptree.BPTree, id uint64) (any, bool) {
	key := uint64Key(id)
	if !store.Has(key) {
		return nil, false
	}
	return store.Get(key), true
}

func treeSet(store *bptree.BPTree, id uint64, value any) {
	store.Set(uint64Key(id), value)
}

func stringGet(store *bptree.BPTree, key string) (any, bool) {
	if !store.Has(key) {
		return nil, false
	}
	return store.Get(key), true
}

func addStringSetID(store *bptree.BPTree, key string, id uint64) {
	value := store.Get(key)
	var ids *bptree.BPTree
	if value != nil {
		ids = value.(*bptree.BPTree)
	} else {
		ids = bptree.NewBPTree32()
		store.Set(key, ids)
	}
	ids.Set(uint64Key(id), true)
}

func getStringSet(store *bptree.BPTree, key string) (*bptree.BPTree, bool) {
	value := store.Get(key)
	if value == nil {
		return nil, false
	}
	return value.(*bptree.BPTree), true
}

func getOrCreateIDSet(store *bptree.BPTree, key uint64) *bptree.BPTree {
	value := store.Get(uint64Key(key))
	if value != nil {
		return value.(*bptree.BPTree)
	}
	ids := bptree.NewBPTree32()
	store.Set(uint64Key(key), ids)
	return ids
}

func getIDSet(store *bptree.BPTree, key uint64) (*bptree.BPTree, bool) {
	value := store.Get(uint64Key(key))
	if value == nil {
		return nil, false
	}
	return value.(*bptree.BPTree), true
}

func listIDs(ids *bptree.BPTree, page, count int) []uint64 {
	assertPageCount(page, count)
	result := []uint64{}
	if ids == nil {
		return result
	}
	ids.ReverseIterateByOffset((page-1)*count, count, func(key string, _ any) bool {
		result = append(result, parseUint64Key(key))
		return false
	})
	return result
}
