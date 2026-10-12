package game_vault

import (
	"chain"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestParticipationProcessFundingAndSettlement(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	poolID := vaultTest.CreatePool(cross(cur), "pool:1")
	processID := vaultTest.CreateParticipationProcess(cross(cur), "participation:1", "pool:1", 25)

	firstFundID := vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participant:1", "payment:1", 25)
	secondFundID := vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participant:1", "payment:2", 25)
	vaultTest.DepositParticipation(cross(cur), vaultTest.Player2, processID, "participant:1", "payment:1", 25)

	uassert.Equal(t, firstFundID, GetParticipationFundID(processID, vaultTest.Player1, "payment:1"))
	uassert.Equal(t, 2, GetParticipationFundCount(processID, vaultTest.Player1, "participant:1"))
	ids := ListParticipationFundIDs(processID, vaultTest.Player1, "participant:1", 1, 10)
	uassert.Equal(t, 2, len(ids))
	uassert.Equal(t, secondFundID, ids[0])
	uassert.Equal(t, firstFundID, ids[1])

	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	testing.SetOriginSend(chain.Coins{})
	CloseParticipationProcess(cross(cur), processID)
	CommitParticipationProcess(cross(cur), processID, "commit:1")
	uassert.Equal(t, int(ParticipationProcessStatusCommitted), int(GetParticipationProcess(processID).Status))
	processView := GetParticipationProcessByKey("participation:1")
	uassert.Equal(t, "pool:1", processView.RewardPoolKey)
	uassert.Equal(t, int(ParticipationFundStatusCommitted), int(GetParticipationFundEffectiveStatus(firstFundID)))
	uassert.Equal(t, int64(75), GetRewardPool(poolID).Balance)

	vaultTest.DepositSystemFunding(cross(cur), poolID, "system:1", 25)
	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	testing.SetOriginSend(chain.Coins{})
	LockRewardPool(cross(cur), "pool:1")
	DistributeReward(cross(cur), "pool:1", "distribution:1", vaultTest.Player2.String(), "100")
	distributionView := GetRewardDistributionByOperationKey("distribution:1")
	uassert.Equal(t, "pool:1", distributionView.PoolKey)
	SettleRewardPool(cross(cur), "pool:1")
	uassert.Equal(t, int(RewardPoolStatusSettled), int(GetRewardPoolByKey("pool:1").Status))
}

func TestListParticipationProcessStates(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	vaultTest.CreatePool(cross(cur), "pool:process-states")
	processID := vaultTest.CreateParticipationProcess(cross(cur), "process:states", "pool:process-states", 25)

	states := ListParticipationProcessStates("process:missing", "process:states")
	uassert.Equal(t, 2, len(states))
	uassert.Equal(t, "0", states[0]["processId"])
	uassert.Equal(t, strconv.FormatUint(processID, 10), states[1]["processId"])
	uassert.Equal(t, "pool:process-states", states[1]["rewardPoolKey"])
	uassert.Equal(t, "25", states[1]["participationFee"])
}

func TestListParticipationFundStates(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	vaultTest.CreatePool(cross(cur), "pool:fund-states")
	processID := vaultTest.CreateParticipationProcess(cross(cur), "process:fund-states", "pool:fund-states", 25)
	fundID := vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participation:1", "payment:1", 25)

	states := ListParticipationFundStates(
		strconv.FormatUint(processID, 10), vaultTest.Player1.String(), "payment:missing",
		strconv.FormatUint(processID, 10), vaultTest.Player1.String(), "payment:1",
	)
	uassert.Equal(t, 2, len(states))
	uassert.Equal(t, "0", states[0]["fundId"])
	uassert.Equal(t, strconv.FormatUint(fundID, 10), states[1]["fundId"])
	uassert.Equal(t, strconv.Itoa(int(ParticipationFundStatusHeld)), states[1]["fundEffectiveStatus"])
}

func TestParticipationStateQueriesRejectInvalidBatch(cur realm, t *testing.T) {
	uassert.PanicsWithMessage(t, cur, "participation fund value count mismatch", func() {
		ListParticipationFundStates("1", vaultTest.Player1.String())
	})

	processKeys := []string{}
	fundValues := []string{}
	for index := 0; index <= gameVaultList; index++ {
		processKeys = append(processKeys, "process:1")
		fundValues = append(fundValues, "1", vaultTest.Player1.String(), "payment:1")
	}
	uassert.PanicsWithMessage(t, cur, "count exceeds game vault list limit", func() {
		ListParticipationProcessStates(processKeys...)
	})
	uassert.PanicsWithMessage(t, cur, "count exceeds game vault list limit", func() {
		ListParticipationFundStates(fundValues...)
	})
}

func TestListEntryRefundStates(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	processID := vaultTest.CreateEntryProcess(cross(cur), "entry:states", 25)
	fundID := vaultTest.DepositEntry(cross(cur), vaultTest.Player1, processID, "participation:1", "entry:1", 25)

	states := ListEntryRefundStates(
		"entry:missing,entry:states,entry:states,entry:states",
		strings.Repeat(vaultTest.Player1.String()+",", 3)+vaultTest.Player1.String(),
		"entry:1,entry:missing,entry:1,entry:1",
	)
	uassert.Equal(t, 4, len(states))
	uassert.Equal(t, "entry:missing", states[0]["requestedProcessKey"])
	uassert.Equal(t, "0", states[0]["processId"])
	uassert.Equal(t, "0", states[0]["fundId"])
	uassert.Equal(t, strconv.FormatUint(processID, 10), states[1]["processId"])
	uassert.Equal(t, "0", states[1]["fundId"])
	uassert.Equal(t, "25", states[2]["entryFee"])
	uassert.Equal(t, strconv.FormatUint(fundID, 10), states[2]["fundId"])
	uassert.Equal(t, vaultTest.Player1.String(), states[2]["fundOwner"])
	uassert.Equal(t, "entry:1", states[2]["fundEntryKey"])
	uassert.Equal(t, "participation:1", states[2]["participationKey"])
	uassert.Equal(t, "false", states[2]["fundRefunded"])
	states[2]["fundOwner"] = "changed"
	uassert.Equal(t, vaultTest.Player1.String(), states[3]["fundOwner"])
	uassert.Equal(t, vaultTest.Player1, GetEntryFund(fundID).Owner)

	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	testing.SetOriginSend(chain.Coins{})
	RefundEntryFund(cross(cur), fundID, "refund:entry-states")
	states = ListEntryRefundStates("entry:states", vaultTest.Player1.String(), "entry:1")
	uassert.Equal(t, "true", states[0]["fundRefunded"])
	uassert.Equal(t, "25", states[0]["fundAmount"])
}

func TestPaymentStateQueriesCSV(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	queries := []struct {
		query    func(string, string, string) []map[string]string
		mismatch string
		keyName  string
	}{
		{ListEntryRefundStates, "entry refund value count mismatch", "entry key"},
		{ListParticipationPaymentStates, "participation payment value count mismatch", "payment key"},
	}
	for _, item := range queries {
		uassert.Equal(t, 0, len(item.query("", "", "")))
		uassert.PanicsWithMessage(t, cur, item.mismatch, func() {
			item.query("missing,missing", vaultTest.Player1.String(), "key")
		})
		uassert.PanicsWithMessage(t, cur, "process key length must be between 1 and 128", func() {
			item.query("", vaultTest.Player1.String(), "key")
		})
		uassert.PanicsWithMessage(t, cur, "invalid participation owner", func() {
			item.query("missing", "invalid", "key")
		})
		uassert.PanicsWithMessage(t, cur, item.keyName+" length must be between 1 and 128", func() {
			item.query("missing", vaultTest.Player1.String(), "")
		})
		uassert.PanicsWithMessage(t, cur, "process key length must be between 1 and 128", func() {
			item.query("missing,", vaultTest.Player1.String()+",", "key,")
		})
		uassert.PanicsWithMessage(t, cur, "process key length must be between 1 and 128", func() {
			item.query("missing,,missing", strings.Repeat(vaultTest.Player1.String()+",", 2)+vaultTest.Player1.String(), "key,key,key")
		})
		processes := strings.Repeat("missing,", gameVaultList-1) + "missing"
		owners := strings.Repeat(vaultTest.Player1.String()+",", gameVaultList-1) + vaultTest.Player1.String()
		keys := strings.Repeat("key,", gameVaultList-1) + "key"
		uassert.Equal(t, gameVaultList, len(item.query(processes, owners, keys)))
		uassert.PanicsWithMessage(t, cur, "count exceeds game vault list limit", func() {
			item.query(processes+",missing", owners+","+vaultTest.Player1.String(), keys+",key")
		})
	}
}

func TestListParticipationPaymentStates(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	vaultTest.CreatePool(cross(cur), "pool:payment-states")
	processID := vaultTest.CreateParticipationProcess(cross(cur), "process:states", "pool:payment-states", 25)
	fundID := vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participation:1", "payment:1", 25)
	states := ListParticipationPaymentStates(
		"process:missing,process:states,process:states,process:states",
		strings.Repeat(vaultTest.Player1.String()+",", 3)+vaultTest.Player1.String(),
		"payment:1,payment:missing,payment:1,payment:1",
	)
	uassert.Equal(t, 4, len(states))
	uassert.Equal(t, "process:missing", states[0]["requestedProcessKey"])
	uassert.Equal(t, "0", states[0]["processId"])
	uassert.Equal(t, "0", states[0]["fundId"])
	uassert.Equal(t, strconv.FormatUint(processID, 10), states[1]["processId"])
	uassert.Equal(t, "0", states[1]["fundId"])
	uassert.Equal(t, "25", states[2]["participationFee"])
	uassert.Equal(t, strconv.FormatUint(fundID, 10), states[2]["fundId"])
	uassert.Equal(t, "payment:1", states[2]["fundPaymentKey"])
	uassert.Equal(t, "participation:1", states[2]["participationKey"])
	uassert.Equal(t, "1", states[2]["fundEffectiveStatus"])
	states[2]["fundOwner"] = "changed"
	uassert.Equal(t, vaultTest.Player1.String(), states[3]["fundOwner"])
	uassert.Equal(t, vaultTest.Player1, GetParticipationFund(fundID).Owner)

	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	testing.SetOriginSend(chain.Coins{})
	RefundParticipationFund(cross(cur), fundID, "refund:payment-states")
	states = ListParticipationPaymentStates("process:states", vaultTest.Player1.String(), "payment:1")
	uassert.Equal(t, "true", states[0]["fundRefunded"])
	uassert.Equal(t, "3", states[0]["fundEffectiveStatus"])
	CloseParticipationProcess(cross(cur), processID)
	CommitParticipationProcess(cross(cur), processID, "commit:payment-states")
	states = ListParticipationPaymentStates("process:states", vaultTest.Player1.String(), "payment:1")
	uassert.Equal(t, "3", states[0]["processStatus"])
	uassert.Equal(t, "3", states[0]["fundEffectiveStatus"])
}

func TestParticipationPaymentValidation(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	vaultTest.CreatePool(cross(cur), "pool:validation")
	processID := vaultTest.CreateParticipationProcess(cross(cur), "participation:validation", "pool:validation", 25)

	uassert.AbortsWithMessage(t, cur, "exact payment required: expected 25ugnot, got 24ugnot", func() {
		vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participant:1", "payment:under", 24)
	})
	uassert.AbortsWithMessage(t, cur, "exact payment required: expected 25ugnot, got 26ugnot", func() {
		vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participant:1", "payment:over", 26)
	})
	testing.SetOriginCaller(vaultTest.Player1)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Player1))
	wrongDenom := chain.Coins{{"utest", 25}}
	testing.IssueCoins(chain.PackageAddress("gno.land/r/akkadia/beta/game_vault"), wrongDenom)
	testing.SetOriginSend(wrongDenom)
	uassert.AbortsWithMessage(t, cur, "exact payment required: expected 25ugnot, got 25utest", func() {
		DepositParticipation(cross(cur), processID, "participant:1", "payment:wrong-denom")
	})
	vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participant:1", "payment:1", 25)
	uassert.AbortsWithMessage(t, cur, "payment key already processed", func() {
		vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participant:2", "payment:1", 25)
	})
}

func TestVaultRejectsUnexpectedCoinsAndOverflow(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	coins := chain.Coins{{"ugnot", 1}}
	testing.IssueCoins(chain.PackageAddress("gno.land/r/akkadia/beta/game_vault"), coins)
	testing.SetOriginSend(coins)
	uassert.AbortsWithMessage(t, cur, "attached coins not allowed", func() {
		CreateRewardPool(cross(cur), "pool:coins", vaultTest.GameWorldID)
	})

	vaultTest.CreatePool(cross(cur), "pool:overflow")
	processID := vaultTest.CreateParticipationProcess(cross(cur), "participation:overflow", "pool:overflow", 1)
	accountedUgnotTotal = maxInt64
	uassert.AbortsWithMessage(t, cur, "vault fund amount overflow", func() {
		vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participant:1", "payment:overflow", 1)
	})
}

func TestVaultRejectsMissingGameWorld(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	testing.SetOriginSend(chain.Coins{})

	uassert.AbortsWithMessage(t, cur, "game world not found: 2", func() {
		CreateRewardPool(cross(cur), "pool:missing-world", vaultTest.GameWorldID+1)
	})
}

func TestParticipationProcessRequiresRewardPoolKey(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	uassert.AbortsWithMessage(t, cur, "reward pool not found: pool:missing", func() {
		vaultTest.CreateParticipationProcess(cross(cur), "participation:missing", "pool:missing", 10)
	})
}

func TestEntryProcessFundingAndRefund(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	processID := vaultTest.CreateEntryProcess(cross(cur), "entry:1", 10)

	firstFundID := vaultTest.DepositEntry(cross(cur), vaultTest.Player1, processID, "participant:1", "entry:1", 10)
	secondFundID := vaultTest.DepositEntry(cross(cur), vaultTest.Player1, processID, "participant:1", "entry:2", 10)
	vaultTest.DepositEntry(cross(cur), vaultTest.Player2, processID, "participant:1", "entry:1", 10)

	uassert.Equal(t, firstFundID, GetEntryFundID(processID, vaultTest.Player1, "entry:1"))
	uassert.Equal(t, 2, GetEntryFundCount(processID, vaultTest.Player1, "participant:1"))
	ids := ListEntryFundIDs(processID, vaultTest.Player1, "participant:1", 1, 10)
	uassert.Equal(t, 2, len(ids))
	uassert.Equal(t, secondFundID, ids[0])
	uassert.Equal(t, firstFundID, ids[1])

	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	testing.SetOriginSend(chain.Coins{})
	CloseEntryProcess(cross(cur), processID)
	RefundEntryFund(cross(cur), firstFundID, "entry-refund:1")
	uassert.Equal(t, int(EntryFundStatusRefunded), int(GetEntryFundStatus(firstFundID)))
	uassert.Equal(t, int64(20), GetEntryProcess(processID).HeldBalance)
}

func TestEntryProcessValidationAndCancel(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	uassert.AbortsWithMessage(t, cur, "entry fee must be positive", func() {
		vaultTest.CreateEntryProcess(cross(cur), "entry:free", 0)
	})
	processID := vaultTest.CreateEntryProcess(cross(cur), "entry:cancel", 10)
	vaultTest.DepositEntry(cross(cur), vaultTest.Player1, processID, "participant:1", "entry:1", 10)
	uassert.AbortsWithMessage(t, cur, "entry key already processed", func() {
		vaultTest.DepositEntry(cross(cur), vaultTest.Player1, processID, "participant:2", "entry:1", 10)
	})

	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	testing.SetOriginSend(chain.Coins{})
	CancelEntryProcess(cross(cur), processID)
	uassert.Equal(t, int(EntryProcessStatusCanceled), int(GetEntryProcess(processID).Status))
	uassert.AbortsWithMessage(t, cur, "entry process is not open", func() {
		vaultTest.DepositEntry(cross(cur), vaultTest.Player2, processID, "participant:2", "entry:2", 10)
	})
}
