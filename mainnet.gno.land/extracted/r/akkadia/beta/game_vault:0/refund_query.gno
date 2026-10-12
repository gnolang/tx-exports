package game_vault

import "strconv"

// ListRefundScopeStates returns participation process and reward pool states for refund decisions.
func ListRefundScopeStates(scopeKeys ...string) []map[string]string {
	if len(scopeKeys)%2 != 0 {
		panic("refund scope key count mismatch")
	}
	if len(scopeKeys)/2 > gameVaultList {
		panic("count exceeds game vault list limit")
	}

	result := []map[string]string{}
	for index := 0; index < len(scopeKeys); index += 2 {
		processKey := scopeKeys[index]
		rewardPoolKey := scopeKeys[index+1]
		assertKeyLength(processKey, "process key")
		assertKeyLength(rewardPoolKey, "pool key")

		state := map[string]string{
			"requestedProcessKey":    processKey,
			"requestedRewardPoolKey": rewardPoolKey,
			"processId":              "0",
			"processKey":             "",
			"processGameWorldId":     "0",
			"processRewardPoolKey":   "",
			"participationFee":       "0",
			"processStatus":          "0",
			"rewardPoolId":           "0",
			"rewardPoolKey":          "",
			"rewardPoolGameWorldId":  "0",
			"rewardPoolStatus":       "0",
		}

		processID := GetParticipationProcessID(processKey)
		if processID != 0 {
			process := GetParticipationProcess(processID)
			state["processId"] = strconv.FormatUint(process.ID, 10)
			state["processKey"] = process.ProcessKey
			state["processGameWorldId"] = strconv.FormatUint(process.GameWorldID, 10)
			state["processRewardPoolKey"] = GetRewardPool(process.RewardPoolID).PoolKey
			state["participationFee"] = strconv.FormatInt(process.ParticipationFee, 10)
			state["processStatus"] = strconv.Itoa(int(process.Status))
		}

		rewardPoolID := GetRewardPoolID(rewardPoolKey)
		if rewardPoolID != 0 {
			pool := GetRewardPool(rewardPoolID)
			state["rewardPoolId"] = strconv.FormatUint(pool.ID, 10)
			state["rewardPoolKey"] = pool.PoolKey
			state["rewardPoolGameWorldId"] = strconv.FormatUint(pool.GameWorldID, 10)
			state["rewardPoolStatus"] = strconv.Itoa(int(pool.Status))
		}

		result = append(result, state)
	}
	return result
}

// ListParticipationRefundStates returns fund, processed operation, and refund evidence for each participant.
func ListParticipationRefundStates(values ...string) []map[string]string {
	if len(values)%4 != 0 {
		panic("participation refund value count mismatch")
	}
	if len(values)/4 > gameVaultList {
		panic("count exceeds game vault list limit")
	}

	result := []map[string]string{}
	for index := 0; index < len(values); index += 4 {
		processID, err := strconv.ParseUint(values[index], 10, 64)
		if err != nil || processID == 0 {
			panic("invalid participation process id")
		}
		owner := address(values[index+1])
		paymentKey := values[index+2]
		operationKey := values[index+3]
		assertValidOwner(owner)
		assertKeyLength(paymentKey, "payment key")
		assertKeyLength(operationKey, "operation key")

		state := map[string]string{
			"processId":           strconv.FormatUint(processID, 10),
			"owner":               owner.String(),
			"paymentKey":          paymentKey,
			"operationKey":        operationKey,
			"fundId":              "0",
			"fundProcessId":       "0",
			"participationKey":    "",
			"fundPaymentKey":      "",
			"fundOwner":           "",
			"fundAmount":          "0",
			"fundRefunded":        "false",
			"fundEffectiveStatus": "0",
			"operationProcessed":  strconv.FormatBool(HasProcessedOperationKey(operationKey)),
			"refundId":            "0",
			"refundPoolId":        "0",
			"refundOperationKey":  "",
			"refundSourceKey":     "",
			"refundRecipient":     "",
			"refundAmount":        "0",
			"refundKind":          "",
		}

		fundID := GetParticipationFundID(processID, owner, paymentKey)
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

		refundIDValue, found := stringGet(vaultRefundIDs, operationKey)
		if found {
			refund := GetVaultRefund(refundIDValue.(uint64))
			state["refundId"] = strconv.FormatUint(refund.ID, 10)
			state["refundPoolId"] = strconv.FormatUint(refund.PoolID, 10)
			state["refundOperationKey"] = refund.OperationKey
			state["refundSourceKey"] = refund.SourceKey
			state["refundRecipient"] = refund.Recipient.String()
			state["refundAmount"] = strconv.FormatInt(refund.Amount, 10)
			state["refundKind"] = refund.Kind
		}

		result = append(result, state)
	}
	return result
}
