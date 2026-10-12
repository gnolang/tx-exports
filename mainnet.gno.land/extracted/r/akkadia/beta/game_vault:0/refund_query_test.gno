package game_vault

import (
	"chain"
	"strconv"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestListRefundScopeStates(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	vaultTest.CreatePool(cross(cur), "pool:refund-query")
	processID := vaultTest.CreateParticipationProcess(cross(cur), "process:refund-query", "pool:refund-query", 25)

	states := ListRefundScopeStates(
		"process:missing", "pool:missing",
		"process:refund-query", "pool:refund-query",
	)
	uassert.Equal(t, 2, len(states))
	uassert.Equal(t, "0", states[0]["processId"])
	uassert.Equal(t, "0", states[0]["rewardPoolId"])
	uassert.Equal(t, strconv.FormatUint(processID, 10), states[1]["processId"])
	uassert.Equal(t, strconv.Itoa(int(ParticipationProcessStatusOpen)), states[1]["processStatus"])
	uassert.Equal(t, strconv.Itoa(int(RewardPoolStatusOpen)), states[1]["rewardPoolStatus"])
}

func TestListParticipationRefundStates(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	poolID := vaultTest.CreatePool(cross(cur), "pool:participation-refund-query")
	processID := vaultTest.CreateParticipationProcess(cross(cur), "process:participation-refund-query", "pool:participation-refund-query", 25)
	fundID := vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participation:1", "payment:1", 25)

	before := ListParticipationRefundStates(
		strconv.FormatUint(processID, 10), vaultTest.Player1.String(), "payment:1", "refund:1",
		strconv.FormatUint(processID, 10), vaultTest.Player1.String(), "payment:missing", "refund:missing",
	)
	uassert.Equal(t, strconv.FormatUint(fundID, 10), before[0]["fundId"])
	uassert.Equal(t, strconv.Itoa(int(ParticipationFundStatusHeld)), before[0]["fundEffectiveStatus"])
	uassert.Equal(t, "false", before[0]["operationProcessed"])
	uassert.Equal(t, "0", before[1]["fundId"])

	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	testing.SetOriginSend(chain.Coins{})
	RefundParticipationFund(cross(cur), fundID, "refund:1")

	after := ListParticipationRefundStates(
		strconv.FormatUint(processID, 10), vaultTest.Player1.String(), "payment:1", "refund:1",
	)
	uassert.Equal(t, "true", after[0]["fundRefunded"])
	uassert.Equal(t, "true", after[0]["operationProcessed"])
	uassert.Equal(t, strconv.FormatUint(poolID, 10), after[0]["refundPoolId"])
	uassert.Equal(t, "payment:1", after[0]["refundSourceKey"])
}

func TestRefundStateQueriesRejectMismatchedValues(cur realm, t *testing.T) {
	uassert.PanicsWithMessage(t, cur, "refund scope key count mismatch", func() {
		ListRefundScopeStates("process:1")
	})
	uassert.PanicsWithMessage(t, cur, "participation refund value count mismatch", func() {
		ListParticipationRefundStates("1", vaultTest.Player1.String(), "payment:1")
	})

	scopeKeys := []string{}
	refundValues := []string{}
	for index := 0; index <= gameVaultList; index++ {
		scopeKeys = append(scopeKeys, "process:1", "pool:1")
		refundValues = append(refundValues, "1", vaultTest.Player1.String(), "payment:1", "refund:1")
	}
	uassert.PanicsWithMessage(t, cur, "count exceeds game vault list limit", func() {
		ListRefundScopeStates(scopeKeys...)
	})
	uassert.PanicsWithMessage(t, cur, "count exceeds game vault list limit", func() {
		ListParticipationRefundStates(refundValues...)
	})
}
