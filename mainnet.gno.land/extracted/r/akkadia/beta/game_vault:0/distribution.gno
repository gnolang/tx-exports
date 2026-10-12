package game_vault

import (
	"chain"
	"chain/banker"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/r/akkadia/beta/admin"
)

const (
	SetDistributionBatchMaxEvent   = "SetDistributionBatchMax"
	distributionBatchMaxDefault    = 50
	distributionBatchMaxUpperBound = 100
)

var distributionBatchMax int

type RewardDistribution struct {
	ID             uint64
	PoolID         uint64
	GameWorldID    uint64
	OperationKey   string
	RecipientCount uint32
	TotalAmount    int64
	Executor       address
}

type RewardDistributionView struct {
	ID             uint64
	PoolKey        string
	GameWorldID    uint64
	OperationKey   string
	RecipientCount uint32
	TotalAmount    int64
	Executor       address
}

type VaultRefund struct {
	ID           uint64
	PoolID       uint64
	OperationKey string
	SourceKey    string
	Recipient    address
	Amount       int64
	Kind         string
	Executor     address
}

func SetDistributionBatchMax(cur realm, value int) {
	executor := accesscontrol.MustGetAdminCaller(0, cur, admin.IsAdmin)
	assertNoAttachedCoins()
	if value < 1 {
		panic("limit must be at least 1")
	}
	if value > distributionBatchMaxUpperBound {
		panic("distribution batch max exceeds limit")
	}
	if value == distributionBatchMax {
		return
	}
	oldValue := distributionBatchMax
	distributionBatchMax = value
	chain.Emit(SetDistributionBatchMaxEvent, "executor", executor.String(), "oldValue", strconv.Itoa(oldValue), "newValue", strconv.Itoa(value))
}

func GetDistributionBatchMax() int { return distributionBatchMax }

func DistributeReward(cur realm, poolKey string, operationKey, recipientCSV, ugnotAmountCSV string) uint64 {
	executor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	assertNewOperationKey(operationKey)
	poolID, pool := mustGetRewardPoolByKey(poolKey)
	if pool.Status != RewardPoolStatusLocked {
		panic("reward pool must be locked before distribution")
	}
	if latestRewardDistributionID == maxUint64 {
		panic("reward distribution id exhausted")
	}
	if recipientCSV == "" || ugnotAmountCSV == "" {
		panic("payout list must not be empty")
	}

	count, total := validatePayouts(recipientCSV, ugnotAmountCSV, cur.Address(), pool.Balance)
	if pool.DistributedTotal > maxInt64-total {
		panic("reward pool distributed amount overflow")
	}
	if pool.DistributionCount == maxUint64 {
		panic("reward pool distribution count overflow")
	}

	latestRewardDistributionID++
	distributionID := latestRewardDistributionID
	pool.Balance -= total
	pool.DistributedTotal += total
	pool.DistributionCount++
	treeSet(rewardPools, poolID, pool)
	treeSet(rewardDistributions, distributionID, RewardDistribution{
		ID:             distributionID,
		PoolID:         poolID,
		GameWorldID:    pool.GameWorldID,
		OperationKey:   operationKey,
		RecipientCount: uint32(count),
		TotalAmount:    total,
		Executor:       executor,
	})
	rewardDistributionIDs.Set(operationKey, distributionID)
	processedOperationKeys.Set(operationKey, distributionID)
	getOrCreateIDSet(poolDistributionIDs, poolID).Set(uint64Key(distributionID), true)
	accountedUgnotTotal -= total
	sendPayouts(cross(cur), recipientCSV, ugnotAmountCSV)
	return distributionID
}

func recordAndSendRefund(cur realm, poolID uint64, operationKey, sourceKey string, recipient address, amount int64, kind string, executor address) uint64 {
	if latestVaultRefundID == maxUint64 {
		panic("vault refund id exhausted")
	}
	latestVaultRefundID++
	refundID := latestVaultRefundID
	treeSet(vaultRefunds, refundID, VaultRefund{
		ID:           refundID,
		PoolID:       poolID,
		OperationKey: operationKey,
		SourceKey:    sourceKey,
		Recipient:    recipient,
		Amount:       amount,
		Kind:         kind,
		Executor:     executor,
	})
	vaultRefundIDs.Set(operationKey, refundID)
	processedOperationKeys.Set(operationKey, refundID)
	if poolID != 0 {
		getOrCreateIDSet(poolRefundIDs, poolID).Set(uint64Key(refundID), true)
	}
	sendUgnot(cross(cur), recipient, amount)
	return refundID
}

func validatePayouts(recipientCSV, ugnotAmountCSV string, realmAddress address, balance int64) (int, int64) {
	count := 0
	total := int64(0)
	recipientStart := 0
	amountStart := 0
	for {
		_, nextRecipient, recipientDone := readPayoutRecipient(recipientCSV, recipientStart, realmAddress)
		amount, nextAmount, amountDone := readPayoutAmount(ugnotAmountCSV, amountStart)
		if recipientDone != amountDone {
			panic("payout list item count mismatch")
		}
		count++
		if count > distributionBatchMax {
			panic("payout list exceeds limit")
		}
		if total > maxInt64-amount {
			panic("distribution amount overflow")
		}
		total += amount
		if total > balance {
			panic("distribution amount exceeds reward pool balance")
		}
		if recipientDone {
			return count, total
		}
		recipientStart = nextRecipient
		amountStart = nextAmount
	}
}

func sendPayouts(cur realm, recipientCSV, ugnotAmountCSV string) {
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	recipientStart := 0
	amountStart := 0
	for {
		recipient, nextRecipient, recipientDone := readPayoutRecipient(recipientCSV, recipientStart, cur.Address())
		amount, nextAmount, amountDone := readPayoutAmount(ugnotAmountCSV, amountStart)
		if recipientDone != amountDone {
			panic("payout list item count mismatch")
		}
		bnk.SendCoins(cur.Address(), recipient, chain.Coins{{"ugnot", amount}})
		if recipientDone {
			return
		}
		recipientStart = nextRecipient
		amountStart = nextAmount
	}
}

func readPayoutRecipient(recipientCSV string, start int, realmAddress address) (address, int, bool) {
	value, next, done := readPayoutCSVEntry(recipientCSV, start)
	recipient := address(value)
	if !recipient.IsValid() || recipient == realmAddress {
		panic("invalid payout recipient")
	}
	return recipient, next, done
}

func readPayoutAmount(ugnotAmountCSV string, start int) (int64, int, bool) {
	value, next, done := readPayoutCSVEntry(ugnotAmountCSV, start)
	amount, err := strconv.ParseInt(value, 10, 64)
	if err != nil || amount <= 0 {
		panic("invalid payout amount")
	}
	return amount, next, done
}

func readPayoutCSVEntry(csv string, start int) (string, int, bool) {
	end := start
	for end < len(csv) && csv[end] != ',' {
		end++
	}
	if end == start {
		panic("payout entry must not be empty")
	}
	if end == len(csv) {
		return csv[start:end], 0, true
	}
	next := end + 1
	if next == len(csv) {
		panic("payout entry must not be empty")
	}
	return csv[start:end], next, false
}

func GetRewardDistribution(distributionID uint64) RewardDistribution {
	value, found := treeGet(rewardDistributions, distributionID)
	if !found {
		panic("reward distribution not found: " + strconv.FormatUint(distributionID, 10))
	}
	return value.(RewardDistribution)
}

func GetLatestRewardDistributionID() uint64 { return latestRewardDistributionID }

func GetRewardDistributionByOperationKey(operationKey string) RewardDistributionView {
	assertKeyLength(operationKey, "operation key")
	value, found := stringGet(rewardDistributionIDs, operationKey)
	if !found {
		panic("reward distribution not found: " + operationKey)
	}
	distribution := GetRewardDistribution(value.(uint64))
	return RewardDistributionView{
		ID:             distribution.ID,
		PoolKey:        GetRewardPool(distribution.PoolID).PoolKey,
		GameWorldID:    distribution.GameWorldID,
		OperationKey:   distribution.OperationKey,
		RecipientCount: distribution.RecipientCount,
		TotalAmount:    distribution.TotalAmount,
		Executor:       distribution.Executor,
	}
}

func GetRewardDistributionCountByPool(poolID uint64) int {
	GetRewardPool(poolID)
	ids, found := getIDSet(poolDistributionIDs, poolID)
	if !found {
		return 0
	}
	return ids.Size()
}

func ListRewardDistributionIDsByPool(poolID uint64, page, count int) []uint64 {
	GetRewardPool(poolID)
	ids, _ := getIDSet(poolDistributionIDs, poolID)
	return listIDs(ids, page, count)
}

func GetVaultRefund(refundID uint64) VaultRefund {
	value, found := treeGet(vaultRefunds, refundID)
	if !found {
		panic("vault refund not found: " + strconv.FormatUint(refundID, 10))
	}
	return value.(VaultRefund)
}

func GetLatestVaultRefundID() uint64 { return latestVaultRefundID }

func GetVaultRefundByOperationKey(operationKey string) VaultRefund {
	assertKeyLength(operationKey, "operation key")
	value, found := stringGet(vaultRefundIDs, operationKey)
	if !found {
		panic("vault refund not found: " + operationKey)
	}
	return GetVaultRefund(value.(uint64))
}

func GetVaultRefundCountByPool(poolID uint64) int {
	GetRewardPool(poolID)
	ids, found := getIDSet(poolRefundIDs, poolID)
	if !found {
		return 0
	}
	return ids.Size()
}

func ListVaultRefundIDsByPool(poolID uint64, page, count int) []uint64 {
	GetRewardPool(poolID)
	ids, _ := getIDSet(poolRefundIDs, poolID)
	return listIDs(ids, page, count)
}
