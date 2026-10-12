package game_vault

import (
	"strconv"

	"gno.land/p/akkadia/beta/accesscontrol"
	"gno.land/r/akkadia/beta/admin"
)

type EntryProcessStatus int

const (
	EntryProcessStatusInvalid EntryProcessStatus = iota
	EntryProcessStatusOpen
	EntryProcessStatusClosed
	EntryProcessStatusCanceled
)

type EntryFundStatus int

const (
	EntryFundStatusInvalid EntryFundStatus = iota
	EntryFundStatusHeld
	EntryFundStatusRefunded
)

type EntryProcess struct {
	ID            uint64
	ProcessKey    string
	GameWorldID   uint64
	EntryFee      int64
	Status        EntryProcessStatus
	HeldBalance   int64
	RefundedTotal int64
	FundCount     uint64
}

type EntryFund struct {
	ID               uint64
	ProcessID        uint64
	ParticipationKey string
	EntryKey         string
	Owner            address
	Amount           int64
	Refunded         bool
}

func CreateEntryProcess(cur realm, processKey string, gameWorldID uint64, entryFeeUgnot int64) uint64 {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	assertKeyLength(processKey, "process key")
	if entryProcessIDs.Has(processKey) {
		panic("entry process key already exists")
	}
	if entryFeeUgnot <= 0 {
		panic("entry fee must be positive")
	}
	assertGameWorldExists(gameWorldID)
	if latestEntryProcessID == maxUint64 {
		panic("entry process id exhausted")
	}

	latestEntryProcessID++
	processID := latestEntryProcessID
	treeSet(entryProcesses, processID, EntryProcess{
		ID:          processID,
		ProcessKey:  processKey,
		GameWorldID: gameWorldID,
		EntryFee:    entryFeeUgnot,
		Status:      EntryProcessStatusOpen,
	})
	entryProcessIDs.Set(processKey, processID)
	getOrCreateIDSet(gameWorldEntryProcessIDs, gameWorldID).Set(uint64Key(processID), true)
	return processID
}

func CloseEntryProcess(cur realm, processID uint64) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	process := GetEntryProcess(processID)
	if process.Status == EntryProcessStatusClosed {
		return
	}
	if process.Status != EntryProcessStatusOpen {
		panic("entry process cannot be closed")
	}
	process.Status = EntryProcessStatusClosed
	treeSet(entryProcesses, processID, process)
}

func CancelEntryProcess(cur realm, processID uint64) {
	accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	process := GetEntryProcess(processID)
	if process.Status == EntryProcessStatusCanceled {
		return
	}
	if process.Status != EntryProcessStatusOpen && process.Status != EntryProcessStatusClosed {
		panic("entry process cannot be canceled")
	}
	process.Status = EntryProcessStatusCanceled
	treeSet(entryProcesses, processID, process)
}

func DepositEntry(cur realm, processID uint64, participationKey, entryKey string) uint64 {
	owner := accesscontrol.MustGetUserCaller(0, cur)
	assertKeyLength(participationKey, "participation key")
	assertKeyLength(entryKey, "entry key")
	process := GetEntryProcess(processID)
	if process.Status != EntryProcessStatusOpen {
		panic("entry process is not open")
	}
	entryIndexKey := keyedOwnerKey(processID, owner, entryKey)
	if entryFundIDs.Has(entryIndexKey) {
		panic("entry key already processed")
	}
	assertExactUgnotPayment(process.EntryFee)
	if latestEntryFundID == maxUint64 || process.FundCount == maxUint64 {
		panic("entry fund id exhausted")
	}
	if process.HeldBalance > maxInt64-process.EntryFee || accountedUgnotTotal > maxInt64-process.EntryFee {
		panic("vault fund amount overflow")
	}

	latestEntryFundID++
	fundID := latestEntryFundID
	treeSet(entryFunds, fundID, EntryFund{
		ID:               fundID,
		ProcessID:        processID,
		ParticipationKey: participationKey,
		EntryKey:         entryKey,
		Owner:            owner,
		Amount:           process.EntryFee,
	})
	entryFundIDs.Set(entryIndexKey, fundID)
	addStringSetID(entryOwnerFundIDs, ownerKey(processID, owner), fundID)
	addStringSetID(entryGroupFundIDs, keyedOwnerKey(processID, owner, participationKey), fundID)
	process.HeldBalance += process.EntryFee
	process.FundCount++
	treeSet(entryProcesses, processID, process)
	accountedUgnotTotal += process.EntryFee
	return fundID
}

func RefundEntryFund(cur realm, fundID uint64, operationKey string) uint64 {
	executor := accesscontrol.MustGetAdminOrOperatorCaller(0, cur, admin.IsAdmin, admin.IsOperator)
	assertNoAttachedCoins()
	assertNewOperationKey(operationKey)
	fund := GetEntryFund(fundID)
	if fund.Refunded {
		panic("entry fund already refunded")
	}
	process := GetEntryProcess(fund.ProcessID)
	if process.Status != EntryProcessStatusOpen && process.Status != EntryProcessStatusClosed && process.Status != EntryProcessStatusCanceled {
		panic("entry fund cannot be refunded")
	}
	if process.HeldBalance < fund.Amount {
		panic("insufficient entry fund balance")
	}

	process.HeldBalance -= fund.Amount
	process.RefundedTotal += fund.Amount
	treeSet(entryProcesses, process.ID, process)
	fund.Refunded = true
	treeSet(entryFunds, fund.ID, fund)
	return recordAndSendRefund(cross(cur), 0, operationKey, fund.EntryKey, fund.Owner, fund.Amount, "entry", executor)
}

func GetEntryProcessID(processKey string) uint64 {
	assertKeyLength(processKey, "process key")
	value, found := stringGet(entryProcessIDs, processKey)
	if !found {
		return 0
	}
	return value.(uint64)
}

func GetEntryProcess(processID uint64) EntryProcess {
	value, found := treeGet(entryProcesses, processID)
	if !found {
		panic("entry process not found: " + strconv.FormatUint(processID, 10))
	}
	return value.(EntryProcess)
}

func GetLatestEntryProcessID() uint64 { return latestEntryProcessID }

func ListEntryRefundStates(processKeysCSV, ownersCSV, entryKeysCSV string) []map[string]string {
	result := []map[string]string{}
	if processKeysCSV == "" && ownersCSV == "" && entryKeysCSV == "" {
		return result
	}
	processStart, ownerStart, entryStart := 0, 0, 0
	for {
		processKey, processNext, processDone := readQueryCSVEntry(processKeysCSV, processStart)
		ownerValue, ownerNext, ownerDone := readQueryCSVEntry(ownersCSV, ownerStart)
		entryKey, entryNext, entryDone := readQueryCSVEntry(entryKeysCSV, entryStart)
		if processDone != ownerDone || ownerDone != entryDone {
			panic("entry refund value count mismatch")
		}
		if len(result) == gameVaultList {
			panic("count exceeds game vault list limit")
		}
		owner := address(ownerValue)
		processID := GetEntryProcessID(processKey)
		assertValidOwner(owner)
		assertKeyLength(entryKey, "entry key")
		state := map[string]string{
			"requestedProcessKey": processKey,
			"owner":               owner.String(),
			"entryKey":            entryKey,
			"processId":           "0",
			"processKey":          "",
			"entryFee":            "0",
			"processStatus":       "0",
			"fundId":              "0",
			"fundProcessId":       "0",
			"participationKey":    "",
			"fundEntryKey":        "",
			"fundOwner":           "",
			"fundAmount":          "0",
			"fundRefunded":        "false",
		}
		if processID != 0 {
			process := GetEntryProcess(processID)
			state["processId"] = strconv.FormatUint(process.ID, 10)
			state["processKey"] = process.ProcessKey
			state["entryFee"] = strconv.FormatInt(process.EntryFee, 10)
			state["processStatus"] = strconv.Itoa(int(process.Status))
			fundID, found := stringGet(entryFundIDs, keyedOwnerKey(processID, owner, entryKey))
			if found {
				fund := GetEntryFund(fundID.(uint64))
				state["fundId"] = strconv.FormatUint(fund.ID, 10)
				state["fundProcessId"] = strconv.FormatUint(fund.ProcessID, 10)
				state["participationKey"] = fund.ParticipationKey
				state["fundEntryKey"] = fund.EntryKey
				state["fundOwner"] = fund.Owner.String()
				state["fundAmount"] = strconv.FormatInt(fund.Amount, 10)
				state["fundRefunded"] = strconv.FormatBool(fund.Refunded)
			}
		}
		result = append(result, state)
		if processDone {
			return result
		}
		processStart, ownerStart, entryStart = processNext, ownerNext, entryNext
	}
}

func GetEntryFund(fundID uint64) EntryFund {
	value, found := treeGet(entryFunds, fundID)
	if !found {
		panic("entry fund not found: " + strconv.FormatUint(fundID, 10))
	}
	return value.(EntryFund)
}

func GetLatestEntryFundID() uint64 { return latestEntryFundID }

func GetEntryFundStatus(fundID uint64) EntryFundStatus {
	if GetEntryFund(fundID).Refunded {
		return EntryFundStatusRefunded
	}
	return EntryFundStatusHeld
}

func GetEntryFundID(processID uint64, owner address, entryKey string) uint64 {
	GetEntryProcess(processID)
	assertValidOwner(owner)
	assertKeyLength(entryKey, "entry key")
	value, found := stringGet(entryFundIDs, keyedOwnerKey(processID, owner, entryKey))
	if !found {
		return 0
	}
	return value.(uint64)
}

func GetEntryFundCount(processID uint64, owner address, participationKey string) int {
	GetEntryProcess(processID)
	assertValidOwner(owner)
	assertKeyLength(participationKey, "participation key")
	ids, found := getStringSet(entryGroupFundIDs, keyedOwnerKey(processID, owner, participationKey))
	if !found {
		return 0
	}
	return ids.Size()
}

func ListEntryFundIDs(processID uint64, owner address, participationKey string, page, count int) []uint64 {
	GetEntryProcess(processID)
	assertValidOwner(owner)
	assertKeyLength(participationKey, "participation key")
	ids, _ := getStringSet(entryGroupFundIDs, keyedOwnerKey(processID, owner, participationKey))
	return listIDs(ids, page, count)
}

func GetEntryFundCountByOwner(processID uint64, owner address) int {
	GetEntryProcess(processID)
	assertValidOwner(owner)
	ids, found := getStringSet(entryOwnerFundIDs, ownerKey(processID, owner))
	if !found {
		return 0
	}
	return ids.Size()
}

func ListEntryFundIDsByOwner(processID uint64, owner address, page, count int) []uint64 {
	GetEntryProcess(processID)
	assertValidOwner(owner)
	ids, _ := getStringSet(entryOwnerFundIDs, ownerKey(processID, owner))
	return listIDs(ids, page, count)
}
