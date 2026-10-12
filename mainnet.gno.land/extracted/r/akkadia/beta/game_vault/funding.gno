package game_vault

import (
	"chain"
	"chain/banker"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/r/akkadia/beta/admin"
)

type SystemFunding struct {
	ID         uint64
	PoolID     uint64
	FundingKey string
	Depositor  address
	Amount     int64
	Refunded   bool
}

func DepositSystemFunding(cur realm, poolID uint64, fundingKey string) uint64 {
	depositor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertKeyLength(fundingKey, "funding key")
	if systemFundingIDs.Has(fundingKey) {
		panic("funding key already processed")
	}
	pool := GetRewardPool(poolID)
	if pool.Status != RewardPoolStatusOpen {
		panic("reward pool is not open")
	}
	amount := getAttachedUgnotDeposit()
	if latestSystemFundingID == maxUint64 {
		panic("system funding id exhausted")
	}
	if pool.Balance > maxInt64-amount || pool.SystemFundedTotal > maxInt64-amount || accountedUgnotTotal > maxInt64-amount {
		panic("vault fund amount overflow")
	}

	latestSystemFundingID++
	fundingID := latestSystemFundingID
	treeSet(systemFundings, fundingID, SystemFunding{
		ID:         fundingID,
		PoolID:     poolID,
		FundingKey: fundingKey,
		Depositor:  depositor,
		Amount:     amount,
	})
	systemFundingIDs.Set(fundingKey, fundingID)
	getOrCreateIDSet(poolSystemFundingIDs, poolID).Set(uint64Key(fundingID), true)
	pool.SystemFundedTotal += amount
	pool.Balance += amount
	treeSet(rewardPools, poolID, pool)
	accountedUgnotTotal += amount
	return fundingID
}

func RefundSystemFunding(cur realm, poolID uint64, fundingKey, operationKey string) uint64 {
	executor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	assertNewOperationKey(operationKey)
	pool := GetRewardPool(poolID)
	if pool.Status != RewardPoolStatusCanceled {
		panic("reward pool must be canceled before refund")
	}
	funding := GetSystemFundingByKey(fundingKey)
	if funding.PoolID != poolID {
		panic("system funding belongs to another reward pool")
	}
	if funding.Refunded {
		panic("system funding already refunded")
	}
	if pool.Balance < funding.Amount {
		panic("insufficient system funding balance")
	}

	pool.Balance -= funding.Amount
	pool.SystemRefundedTotal += funding.Amount
	treeSet(rewardPools, poolID, pool)
	funding.Refunded = true
	treeSet(systemFundings, funding.ID, funding)
	return recordAndSendRefund(cross(cur), poolID, operationKey, fundingKey, funding.Depositor, funding.Amount, "system", executor)
}

func GetSystemFunding(fundingID uint64) SystemFunding {
	value, found := treeGet(systemFundings, fundingID)
	if !found {
		panic("system funding not found: " + strconv.FormatUint(fundingID, 10))
	}
	return value.(SystemFunding)
}

func GetLatestSystemFundingID() uint64 { return latestSystemFundingID }

func GetSystemFundingByKey(fundingKey string) SystemFunding {
	assertKeyLength(fundingKey, "funding key")
	value, found := stringGet(systemFundingIDs, fundingKey)
	if !found {
		panic("system funding not found: " + fundingKey)
	}
	return GetSystemFunding(value.(uint64))
}

func GetSystemFundingCountByPool(poolID uint64) int {
	GetRewardPool(poolID)
	ids, found := getIDSet(poolSystemFundingIDs, poolID)
	if !found {
		return 0
	}
	return ids.Size()
}

func ListSystemFundingIDsByPool(poolID uint64, page, count int) []uint64 {
	GetRewardPool(poolID)
	ids, _ := getIDSet(poolSystemFundingIDs, poolID)
	return listIDs(ids, page, count)
}

func GetAccountedUgnotTotal() int64 { return accountedUgnotTotal }

func GetUnaccountedUgnotTotal() int64 {
	actual := banker.NewReadonlyBanker().GetCoins(chain.PackageAddress("gno.land/r/akkadia/beta/game_vault")).AmountOf("ugnot")
	if actual < accountedUgnotTotal {
		panic("vault fund accounting exceeds realm balance")
	}
	return actual - accountedUgnotTotal
}
