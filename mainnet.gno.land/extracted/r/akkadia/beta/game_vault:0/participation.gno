package game_vault

import (
	"chain"
	"chain/banker"
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/r/akkadia/beta/admin"
)

type ParticipationProcessStatus int

const (
	ParticipationProcessStatusInvalid ParticipationProcessStatus = iota
	ParticipationProcessStatusOpen
	ParticipationProcessStatusClosed
	ParticipationProcessStatusCommitted
	ParticipationProcessStatusCanceled
)

type ParticipationFundStatus int

const (
	ParticipationFundStatusInvalid ParticipationFundStatus = iota
	ParticipationFundStatusHeld
	ParticipationFundStatusCommitted
	ParticipationFundStatusRefunded
)

type ParticipationProcess struct {
	ID               uint64
	ProcessKey       string
	GameWorldID      uint64
	RewardPoolID     uint64
	ParticipationFee int64
	Status           ParticipationProcessStatus
	HeldBalance      int64
	CommittedTotal   int64
	RefundedTotal    int64
	FundCount        uint64
}

type ParticipationProcessView struct {
	ID               uint64
	ProcessKey       string
	GameWorldID      uint64
	RewardPoolKey    string
	ParticipationFee int64
	Status           ParticipationProcessStatus
	HeldBalance      int64
	CommittedTotal   int64
	RefundedTotal    int64
	FundCount        uint64
}

type ParticipationFund struct {
	ID               uint64
	ProcessID        uint64
	ParticipationKey string
	PaymentKey       string
	Owner            address
	Amount           int64
	Refunded         bool
}

func CreateParticipationProcess(cur realm, processKey string, gameWorldID uint64, rewardPoolKey string, participationFeeUgnot int64) uint64 {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	assertKeyLength(processKey, "process key")
	assertKeyLength(rewardPoolKey, "reward pool key")
	if participationProcessIDs.Has(processKey) {
		panic("participation process key already exists")
	}
	if participationFeeUgnot <= 0 {
		panic("participation fee must be positive")
	}
	assertGameWorldExists(gameWorldID)
	rewardPoolID := GetRewardPoolID(rewardPoolKey)
	if rewardPoolID == 0 {
		panic("reward pool not found: " + rewardPoolKey)
	}
	pool := GetRewardPool(rewardPoolID)
	if pool.GameWorldID != gameWorldID {
		panic("reward pool belongs to another game world")
	}
	if pool.Status != RewardPoolStatusOpen {
		panic("reward pool is not open")
	}
	if latestParticipationProcessID == maxUint64 {
		panic("participation process id exhausted")
	}

	latestParticipationProcessID++
	processID := latestParticipationProcessID
	treeSet(participationProcesses, processID, ParticipationProcess{
		ID:               processID,
		ProcessKey:       processKey,
		GameWorldID:      gameWorldID,
		RewardPoolID:     rewardPoolID,
		ParticipationFee: participationFeeUgnot,
		Status:           ParticipationProcessStatusOpen,
	})
	participationProcessIDs.Set(processKey, processID)
	getOrCreateIDSet(gameWorldParticipationProcessIDs, gameWorldID).Set(uint64Key(processID), true)
	return processID
}

func CloseParticipationProcess(cur realm, processID uint64) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	process := GetParticipationProcess(processID)
	if process.Status == ParticipationProcessStatusClosed {
		return
	}
	if process.Status != ParticipationProcessStatusOpen {
		panic("participation process cannot be closed")
	}
	process.Status = ParticipationProcessStatusClosed
	treeSet(participationProcesses, processID, process)
}

func CancelParticipationProcess(cur realm, processID uint64) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	process := GetParticipationProcess(processID)
	if process.Status == ParticipationProcessStatusCanceled {
		return
	}
	if process.Status != ParticipationProcessStatusOpen && process.Status != ParticipationProcessStatusClosed {
		panic("participation process cannot be canceled")
	}
	process.Status = ParticipationProcessStatusCanceled
	treeSet(participationProcesses, processID, process)
}

func DepositParticipation(cur realm, processID uint64, participationKey, paymentKey string) uint64 {
	owner := accesscontrol.MustGetUserCaller(0, cur)
	assertKeyLength(participationKey, "participation key")
	assertKeyLength(paymentKey, "payment key")
	process := GetParticipationProcess(processID)
	if process.Status != ParticipationProcessStatusOpen {
		panic("participation process is not open")
	}
	paymentIndexKey := keyedOwnerKey(processID, owner, paymentKey)
	if participationFundIDs.Has(paymentIndexKey) {
		panic("payment key already processed")
	}
	assertExactUgnotPayment(process.ParticipationFee)
	if latestParticipationFundID == maxUint64 || process.FundCount == maxUint64 {
		panic("participation fund id exhausted")
	}
	if process.HeldBalance > maxInt64-process.ParticipationFee || accountedUgnotTotal > maxInt64-process.ParticipationFee {
		panic("vault fund amount overflow")
	}

	latestParticipationFundID++
	fundID := latestParticipationFundID
	treeSet(participationFunds, fundID, ParticipationFund{
		ID:               fundID,
		ProcessID:        processID,
		ParticipationKey: participationKey,
		PaymentKey:       paymentKey,
		Owner:            owner,
		Amount:           process.ParticipationFee,
	})
	participationFundIDs.Set(paymentIndexKey, fundID)
	addStringSetID(participationOwnerFundIDs, ownerKey(processID, owner), fundID)
	addStringSetID(participationGroupFundIDs, keyedOwnerKey(processID, owner, participationKey), fundID)
	process.HeldBalance += process.ParticipationFee
	process.FundCount++
	treeSet(participationProcesses, processID, process)
	accountedUgnotTotal += process.ParticipationFee
	return fundID
}

func RefundParticipationFund(cur realm, fundID uint64, operationKey string) uint64 {
	executor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	assertNewOperationKey(operationKey)
	fund := GetParticipationFund(fundID)
	if fund.Refunded {
		panic("participation fund already refunded")
	}
	process := GetParticipationProcess(fund.ProcessID)
	if process.Status != ParticipationProcessStatusOpen && process.Status != ParticipationProcessStatusClosed && process.Status != ParticipationProcessStatusCanceled {
		panic("participation fund cannot be refunded")
	}
	if process.HeldBalance < fund.Amount {
		panic("insufficient participation fund balance")
	}

	process.HeldBalance -= fund.Amount
	process.RefundedTotal += fund.Amount
	treeSet(participationProcesses, process.ID, process)
	fund.Refunded = true
	treeSet(participationFunds, fund.ID, fund)
	return recordAndSendRefund(cross(cur), process.RewardPoolID, operationKey, fund.PaymentKey, fund.Owner, fund.Amount, "participation", executor)
}

func CommitParticipationProcess(cur realm, processID uint64, operationKey string) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	assertNewOperationKey(operationKey)
	process := GetParticipationProcess(processID)
	if process.Status != ParticipationProcessStatusClosed {
		panic("participation process must be closed before commit")
	}
	pool := GetRewardPool(process.RewardPoolID)
	if pool.Status != RewardPoolStatusOpen {
		panic("reward pool is not open")
	}
	amount := process.HeldBalance
	if pool.Balance > maxInt64-amount || pool.ParticipationCommittedTotal > maxInt64-amount || process.CommittedTotal > maxInt64-amount {
		panic("vault fund amount overflow")
	}

	process.HeldBalance = 0
	process.CommittedTotal += amount
	process.Status = ParticipationProcessStatusCommitted
	treeSet(participationProcesses, processID, process)
	pool.ParticipationCommittedTotal += amount
	pool.Balance += amount
	treeSet(rewardPools, pool.ID, pool)
	processedOperationKeys.Set(operationKey, processID)
}

func GetParticipationProcessID(processKey string) uint64 {
	assertKeyLength(processKey, "process key")
	value, found := stringGet(participationProcessIDs, processKey)
	if !found {
		return 0
	}
	return value.(uint64)
}

func GetParticipationProcess(processID uint64) ParticipationProcess {
	value, found := treeGet(participationProcesses, processID)
	if !found {
		panic("participation process not found: " + strconv.FormatUint(processID, 10))
	}
	return value.(ParticipationProcess)
}

func GetParticipationProcessByKey(processKey string) ParticipationProcessView {
	processID := GetParticipationProcessID(processKey)
	if processID == 0 {
		panic("participation process not found: " + processKey)
	}
	process := GetParticipationProcess(processID)
	return ParticipationProcessView{
		ID:               process.ID,
		ProcessKey:       process.ProcessKey,
		GameWorldID:      process.GameWorldID,
		RewardPoolKey:    GetRewardPool(process.RewardPoolID).PoolKey,
		ParticipationFee: process.ParticipationFee,
		Status:           process.Status,
		HeldBalance:      process.HeldBalance,
		CommittedTotal:   process.CommittedTotal,
		RefundedTotal:    process.RefundedTotal,
		FundCount:        process.FundCount,
	}
}

func ListParticipationProcessStates(processKeys ...string) []map[string]string {
	if len(processKeys) > gameVaultList {
		panic("count exceeds game vault list limit")
	}

	result := []map[string]string{}
	for _, processKey := range processKeys {
		processID := GetParticipationProcessID(processKey)
		state := map[string]string{
			"requestedProcessKey": processKey,
			"processId":           "0",
			"processKey":          "",
			"gameWorldId":         "0",
			"rewardPoolKey":       "",
			"participationFee":    "0",
			"processStatus":       "0",
			"heldBalance":         "0",
			"committedTotal":      "0",
			"refundedTotal":       "0",
			"fundCount":           "0",
		}
		if processID != 0 {
			process := GetParticipationProcess(processID)
			state["processId"] = strconv.FormatUint(process.ID, 10)
			state["processKey"] = process.ProcessKey
			state["gameWorldId"] = strconv.FormatUint(process.GameWorldID, 10)
			state["rewardPoolKey"] = GetRewardPool(process.RewardPoolID).PoolKey
			state["participationFee"] = strconv.FormatInt(process.ParticipationFee, 10)
			state["processStatus"] = strconv.Itoa(int(process.Status))
			state["heldBalance"] = strconv.FormatInt(process.HeldBalance, 10)
			state["committedTotal"] = strconv.FormatInt(process.CommittedTotal, 10)
			state["refundedTotal"] = strconv.FormatInt(process.RefundedTotal, 10)
			state["fundCount"] = strconv.FormatUint(process.FundCount, 10)
		}
		result = append(result, state)
	}
	return result
}

func ListParticipationPaymentStates(processKeysCSV, ownersCSV, paymentKeysCSV string) []map[string]string {
	result := []map[string]string{}
	if processKeysCSV == "" && ownersCSV == "" && paymentKeysCSV == "" {
		return result
	}
	processStart, ownerStart, paymentStart := 0, 0, 0
	for {
		processKey, processNext, processDone := readQueryCSVEntry(processKeysCSV, processStart)
		ownerValue, ownerNext, ownerDone := readQueryCSVEntry(ownersCSV, ownerStart)
		paymentKey, paymentNext, paymentDone := readQueryCSVEntry(paymentKeysCSV, paymentStart)
		if processDone != ownerDone || ownerDone != paymentDone {
			panic("participation payment value count mismatch")
		}
		if len(result) == gameVaultList {
			panic("count exceeds game vault list limit")
		}
		processID := GetParticipationProcessID(processKey)
		owner := address(ownerValue)
		assertValidOwner(owner)
		assertKeyLength(paymentKey, "payment key")
		state := map[string]string{
			"requestedProcessKey": processKey,
			"owner":               owner.String(),
			"paymentKey":          paymentKey,
			"processId":           "0",
			"processKey":          "",
			"participationFee":    "0",
			"processStatus":       "0",
			"fundId":              "0",
			"fundProcessId":       "0",
			"participationKey":    "",
			"fundPaymentKey":      "",
			"fundOwner":           "",
			"fundAmount":          "0",
			"fundRefunded":        "false",
			"fundEffectiveStatus": "0",
		}
		if processID != 0 {
			process := GetParticipationProcess(processID)
			state["processId"] = strconv.FormatUint(process.ID, 10)
			state["processKey"] = process.ProcessKey
			state["participationFee"] = strconv.FormatInt(process.ParticipationFee, 10)
			state["processStatus"] = strconv.Itoa(int(process.Status))
			fundID, found := stringGet(participationFundIDs, keyedOwnerKey(processID, owner, paymentKey))
			if found {
				fund := GetParticipationFund(fundID.(uint64))
				state["fundId"] = strconv.FormatUint(fund.ID, 10)
				state["fundProcessId"] = strconv.FormatUint(fund.ProcessID, 10)
				state["participationKey"] = fund.ParticipationKey
				state["fundPaymentKey"] = fund.PaymentKey
				state["fundOwner"] = fund.Owner.String()
				state["fundAmount"] = strconv.FormatInt(fund.Amount, 10)
				state["fundRefunded"] = strconv.FormatBool(fund.Refunded)
				state["fundEffectiveStatus"] = strconv.Itoa(int(GetParticipationFundEffectiveStatus(fund.ID)))
			}
		}
		result = append(result, state)
		if processDone {
			return result
		}
		processStart, ownerStart, paymentStart = processNext, ownerNext, paymentNext
	}
}

func GetLatestParticipationProcessID() uint64 { return latestParticipationProcessID }

func GetParticipationFund(fundID uint64) ParticipationFund {
	value, found := treeGet(participationFunds, fundID)
	if !found {
		panic("participation fund not found: " + strconv.FormatUint(fundID, 10))
	}
	return value.(ParticipationFund)
}

func GetLatestParticipationFundID() uint64 { return latestParticipationFundID }

func GetParticipationFundEffectiveStatus(fundID uint64) ParticipationFundStatus {
	fund := GetParticipationFund(fundID)
	if fund.Refunded {
		return ParticipationFundStatusRefunded
	}
	if GetParticipationProcess(fund.ProcessID).Status == ParticipationProcessStatusCommitted {
		return ParticipationFundStatusCommitted
	}
	return ParticipationFundStatusHeld
}

func GetParticipationFundID(processID uint64, owner address, paymentKey string) uint64 {
	GetParticipationProcess(processID)
	assertValidOwner(owner)
	assertKeyLength(paymentKey, "payment key")
	value, found := stringGet(participationFundIDs, keyedOwnerKey(processID, owner, paymentKey))
	if !found {
		return 0
	}
	return value.(uint64)
}

func ListParticipationFundStates(values ...string) []map[string]string {
	if len(values)%3 != 0 {
		panic("participation fund value count mismatch")
	}
	if len(values)/3 > gameVaultList {
		panic("count exceeds game vault list limit")
	}

	result := []map[string]string{}
	for index := 0; index < len(values); index += 3 {
		processID, err := strconv.ParseUint(values[index], 10, 64)
		if err != nil || processID == 0 {
			panic("invalid participation process id")
		}
		owner := address(values[index+1])
		paymentKey := values[index+2]
		fundID := GetParticipationFundID(processID, owner, paymentKey)
		state := map[string]string{
			"processId":           strconv.FormatUint(processID, 10),
			"owner":               owner.String(),
			"paymentKey":          paymentKey,
			"fundId":              "0",
			"fundProcessId":       "0",
			"participationKey":    "",
			"fundPaymentKey":      "",
			"fundOwner":           "",
			"fundAmount":          "0",
			"fundRefunded":        "false",
			"fundEffectiveStatus": "0",
		}
		if fundID != 0 {
			fund := GetParticipationFund(fundID)
			state["fundId"] = strconv.FormatUint(fund.ID, 10)
			state["fundProcessId"] = strconv.FormatUint(fund.ProcessID, 10)
			state["participationKey"] = fund.ParticipationKey
			state["fundPaymentKey"] = fund.PaymentKey
			state["fundOwner"] = fund.Owner.String()
			state["fundAmount"] = strconv.FormatInt(fund.Amount, 10)
			state["fundRefunded"] = strconv.FormatBool(fund.Refunded)
			state["fundEffectiveStatus"] = strconv.Itoa(int(GetParticipationFundEffectiveStatus(fundID)))
		}
		result = append(result, state)
	}
	return result
}

func GetParticipationFundCount(processID uint64, owner address, participationKey string) int {
	GetParticipationProcess(processID)
	assertValidOwner(owner)
	assertKeyLength(participationKey, "participation key")
	ids, found := getStringSet(participationGroupFundIDs, keyedOwnerKey(processID, owner, participationKey))
	if !found {
		return 0
	}
	return ids.Size()
}

func ListParticipationFundIDs(processID uint64, owner address, participationKey string, page, count int) []uint64 {
	GetParticipationProcess(processID)
	assertValidOwner(owner)
	assertKeyLength(participationKey, "participation key")
	ids, _ := getStringSet(participationGroupFundIDs, keyedOwnerKey(processID, owner, participationKey))
	return listIDs(ids, page, count)
}

func GetParticipationFundCountByOwner(processID uint64, owner address) int {
	GetParticipationProcess(processID)
	assertValidOwner(owner)
	ids, found := getStringSet(participationOwnerFundIDs, ownerKey(processID, owner))
	if !found {
		return 0
	}
	return ids.Size()
}

func ListParticipationFundIDsByOwner(processID uint64, owner address, page, count int) []uint64 {
	GetParticipationProcess(processID)
	assertValidOwner(owner)
	ids, _ := getStringSet(participationOwnerFundIDs, ownerKey(processID, owner))
	return listIDs(ids, page, count)
}

func assertValidOwner(owner address) {
	if !owner.IsValid() {
		panic("invalid participation owner")
	}
}

func sendUgnot(cur realm, recipient address, amount int64) {
	accountedUgnotTotal -= amount
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), recipient, chain.Coins{{"ugnot", amount}})
}
