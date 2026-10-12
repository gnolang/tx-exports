package game_vault

import (
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/r/akkadia/beta/admin"
	gameworld "gno.land/r/akkadia/beta/game_world"
)

const (
	maxInt64      = int64(9223372036854775807)
	maxUint64     = uint64(18446744073709551615)
	gameVaultList = 100
)

type RewardPoolStatus int

const (
	RewardPoolStatusInvalid RewardPoolStatus = iota
	RewardPoolStatusOpen
	RewardPoolStatusLocked
	RewardPoolStatusSettled
	RewardPoolStatusCanceled
)

type RewardPool struct {
	ID                          uint64
	PoolKey                     string
	GameWorldID                 uint64
	Status                      RewardPoolStatus
	ParticipationCommittedTotal int64
	SystemFundedTotal           int64
	SystemRefundedTotal         int64
	DistributedTotal            int64
	Balance                     int64
	DistributionCount           uint64
}

type RewardPoolView struct {
	PoolKey                     string
	GameWorldID                 uint64
	Status                      RewardPoolStatus
	ParticipationCommittedTotal int64
	DistributedTotal            int64
	Balance                     int64
	DistributionCount           uint64
}

func CreateRewardPool(cur realm, poolKey string, gameWorldID uint64) uint64 {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	assertKeyLength(poolKey, "pool key")
	if rewardPoolIDs.Has(poolKey) {
		panic("reward pool key already exists")
	}
	assertGameWorldExists(gameWorldID)
	if latestRewardPoolID == maxUint64 {
		panic("reward pool id exhausted")
	}

	latestRewardPoolID++
	poolID := latestRewardPoolID
	treeSet(rewardPools, poolID, RewardPool{
		ID:          poolID,
		PoolKey:     poolKey,
		GameWorldID: gameWorldID,
		Status:      RewardPoolStatusOpen,
	})
	rewardPoolIDs.Set(poolKey, poolID)
	getOrCreateIDSet(gameWorldRewardPoolIDs, gameWorldID).Set(uint64Key(poolID), true)
	return poolID
}

func LockRewardPool(cur realm, poolKey string) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	poolID, pool := mustGetRewardPoolByKey(poolKey)
	if pool.Status == RewardPoolStatusLocked {
		return
	}
	if pool.Status != RewardPoolStatusOpen {
		panic("reward pool cannot be locked")
	}
	pool.Status = RewardPoolStatusLocked
	treeSet(rewardPools, poolID, pool)
}

func CancelRewardPool(cur realm, poolKey string) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	poolID, pool := mustGetRewardPoolByKey(poolKey)
	if pool.Status == RewardPoolStatusCanceled {
		return
	}
	if pool.Status != RewardPoolStatusOpen {
		panic("reward pool cannot be canceled")
	}
	if pool.ParticipationCommittedTotal != 0 || pool.DistributedTotal != 0 {
		panic("reward pool with committed funds cannot be canceled")
	}
	pool.Status = RewardPoolStatusCanceled
	treeSet(rewardPools, poolID, pool)
}

func SettleRewardPool(cur realm, poolKey string) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	poolID, pool := mustGetRewardPoolByKey(poolKey)
	if pool.Status == RewardPoolStatusSettled {
		return
	}
	if pool.Status != RewardPoolStatusLocked {
		panic("reward pool must be locked before settlement")
	}
	if pool.Balance != 0 {
		panic("reward pool balance must be zero before settlement")
	}
	pool.Status = RewardPoolStatusSettled
	treeSet(rewardPools, poolID, pool)
}

func GetRewardPoolID(poolKey string) uint64 {
	assertKeyLength(poolKey, "pool key")
	value, found := stringGet(rewardPoolIDs, poolKey)
	if !found {
		return 0
	}
	return value.(uint64)
}

func GetRewardPool(poolID uint64) RewardPool {
	value, found := treeGet(rewardPools, poolID)
	if !found {
		panic("reward pool not found: " + strconv.FormatUint(poolID, 10))
	}
	return value.(RewardPool)
}

func GetRewardPoolByKey(poolKey string) RewardPoolView {
	_, pool := mustGetRewardPoolByKey(poolKey)
	return RewardPoolView{
		PoolKey:                     pool.PoolKey,
		GameWorldID:                 pool.GameWorldID,
		Status:                      pool.Status,
		ParticipationCommittedTotal: pool.ParticipationCommittedTotal,
		DistributedTotal:            pool.DistributedTotal,
		Balance:                     pool.Balance,
		DistributionCount:           pool.DistributionCount,
	}
}

func mustGetRewardPoolByKey(poolKey string) (uint64, RewardPool) {
	poolID := GetRewardPoolID(poolKey)
	if poolID == 0 {
		panic("reward pool not found: " + poolKey)
	}
	return poolID, GetRewardPool(poolID)
}

func GetLatestRewardPoolID() uint64 { return latestRewardPoolID }

func GetRewardPoolCountByGameWorld(gameWorldID uint64) int {
	ids, found := getIDSet(gameWorldRewardPoolIDs, gameWorldID)
	if !found {
		return 0
	}
	return ids.Size()
}

func ListRewardPoolIDsByGameWorld(gameWorldID uint64, page, count int) []uint64 {
	ids, _ := getIDSet(gameWorldRewardPoolIDs, gameWorldID)
	return listIDs(ids, page, count)
}

func assertGameWorldExists(gameWorldID uint64) {
	if !gameworld.HasGameWorld(gameWorldID) {
		panic("game world not found: " + strconv.FormatUint(gameWorldID, 10))
	}
}

func assertNoAttachedCoins() {
	if len(unsafe.OriginSend()) != 0 {
		panic("attached coins not allowed")
	}
}

func assertExactUgnotPayment(expected int64) {
	coins := unsafe.OriginSend()
	if len(coins) != 1 || coins[0].Denom != "ugnot" || coins[0].Amount != expected {
		panic("exact payment required: expected " + strconv.FormatInt(expected, 10) + "ugnot, got " + coins.String())
	}
}

func getAttachedUgnotDeposit() int64 {
	coins := unsafe.OriginSend()
	if len(coins) != 1 || coins[0].Denom != "ugnot" || coins[0].Amount <= 0 {
		panic("positive ugnot deposit required")
	}
	return coins[0].Amount
}

func assertKeyLength(value, name string) {
	if len(value) < 1 || len(value) > 128 {
		panic(name + " length must be between 1 and 128")
	}
}

func assertPageCount(page, count int) {
	if page < 1 {
		panic("page must be at least 1")
	}
	if count < 1 {
		panic("count must be at least 1")
	}
	if count > gameVaultList {
		panic("count exceeds game vault list limit")
	}
}

func assertNewOperationKey(operationKey string) {
	assertKeyLength(operationKey, "operation key")
	if processedOperationKeys.Has(operationKey) {
		panic("operation key already processed")
	}
}

func HasProcessedOperationKey(operationKey string) bool {
	return processedOperationKeys.Has(operationKey)
}
