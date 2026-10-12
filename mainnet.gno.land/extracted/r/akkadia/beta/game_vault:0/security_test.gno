package game_vault

import (
	"chain"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestGameVaultCallerSecurity(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	testing.SetOriginCaller(vaultTest.Player1)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Player1))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		CreateRewardPool(cross(cur), "pool:unauthorized", vaultTest.GameWorldID)
	})

	processID := vaultTest.CreateEntryProcess(cross(cur), "entry:security", 10)
	testing.SetOriginCaller(vaultTest.Player1)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/vault_relay"))
	testing.SetOriginSend(chain.Coins{{"ugnot", 10}})
	uassert.AbortsWithMessage(t, cur, "contract calls not allowed: function must be called directly by user", func() {
		DepositEntry(cross(cur), processID, "participant:1", "entry:relay")
	})
}

func TestParticipationRefundExcludesCommittedAmount(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	poolID := vaultTest.CreatePool(cross(cur), "pool:refund")
	processID := vaultTest.CreateParticipationProcess(cross(cur), "participation:refund", "pool:refund", 10)
	refundedFundID := vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participant:1", "payment:refund", 10)
	committedFundID := vaultTest.DepositParticipation(cross(cur), vaultTest.Player1, processID, "participant:1", "payment:commit", 10)

	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	testing.SetOriginSend(chain.Coins{})
	RefundParticipationFund(cross(cur), refundedFundID, "refund:participation")
	CloseParticipationProcess(cross(cur), processID)
	CommitParticipationProcess(cross(cur), processID, "commit:participation")

	uassert.Equal(t, int64(10), GetRewardPool(poolID).Balance)
	uassert.Equal(t, int(ParticipationFundStatusRefunded), int(GetParticipationFundEffectiveStatus(refundedFundID)))
	uassert.Equal(t, int(ParticipationFundStatusCommitted), int(GetParticipationFundEffectiveStatus(committedFundID)))
	uassert.Equal(t, 1, GetVaultRefundCountByPool(poolID))
	uassert.AbortsWithMessage(t, cur, "participation fund cannot be refunded", func() {
		RefundParticipationFund(cross(cur), committedFundID, "refund:committed")
	})
}

func TestSystemFundingCancellationRefundAndReplay(cur realm, t *testing.T) {
	vaultTest.Setup(cross(cur), t)
	poolID := vaultTest.CreatePool(cross(cur), "pool:system-refund")
	fundingID := vaultTest.DepositSystemFunding(cross(cur), poolID, "system:refund", 20)

	testing.SetOriginCaller(vaultTest.Operator)
	testing.SetRealm(testing.NewUserRealm(vaultTest.Operator))
	testing.SetOriginSend(chain.Coins{})
	CancelRewardPool(cross(cur), "pool:system-refund")
	refundID := RefundSystemFunding(cross(cur), poolID, "system:refund", "refund:system")

	uassert.True(t, GetSystemFunding(fundingID).Refunded)
	uassert.Equal(t, int64(0), GetRewardPool(poolID).Balance)
	uassert.Equal(t, refundID, GetVaultRefundByOperationKey("refund:system").ID)
	uassert.AbortsWithMessage(t, cur, "operation key already processed", func() {
		RefundSystemFunding(cross(cur), poolID, "system:refund", "refund:system")
	})
}
