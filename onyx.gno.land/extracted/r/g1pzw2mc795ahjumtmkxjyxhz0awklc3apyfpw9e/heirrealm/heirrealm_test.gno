package heirrealm

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func resetTestState() {
	vaults = avl.Tree{}
	nextVault = 0
}

const testPkgPath = "gno.land/r/g1pzw2mc795ahjumtmkxjyxhz0awklc3apyfpw9e/heirrealm"

// makeVault creates a vault owned by owner for beneficiary with the
// given interval and deposit, funded on the realm so payouts work.
func makeVault(cur realm, t *testing.T, owner, beneficiary address, interval, deposit int64) int {
	pkgAddr := chain.PackageAddress(testPkgPath)
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: deposit}})
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: Denom, Amount: deposit}})
	return CreateVault(cross(cur), beneficiary, interval)
}

func TestCreateVault(cur realm, t *testing.T) {
	defer resetTestState()
	owner := testutils.TestAddress("owner1")
	beneficiary := testutils.TestAddress("beneficiary1")
	id := makeVault(cur, t, owner, beneficiary, 3600, 1000)
	uassert.Equal(t, 1, id)
	uassert.Equal(t, 1, VaultCount())

	v := GetVault(id)
	uassert.Equal(t, owner, v.Owner)
	uassert.Equal(t, beneficiary, v.Beneficiary)
	uassert.Equal(t, int64(1000), v.Balance)
	uassert.Equal(t, int64(3600), v.Interval)
	uassert.Equal(t, "active", v.Status())
	uassert.False(t, v.Released)
	uassert.False(t, v.Cancelled)
	// Deadline is now + 3600s. In tests time.Now() is fixed, so the
	// deadline must be exactly 1h after the fixed test time.
	uassert.True(t, v.Deadline.Equal(time.Now().Add(3600*time.Second)))
	uassert.Equal(t, int64(20), v.KeeperFee()) // 2% of 1000
	uassert.Equal(t, int64(980), v.BeneficiaryShare())
}

func TestCreateVaultGuards(cur realm, t *testing.T) {
	defer resetTestState()
	owner := testutils.TestAddress("owner2")
	other := testutils.TestAddress("other2")

	// Beneficiary must not be the owner.
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 1000}})
	uassert.AbortsContains(t, cur, "must not be the owner", func() {
		CreateVault(cross(cur), owner, 3600)
	})

	// Interval too short (under 60s).
	uassert.AbortsContains(t, cur, "too short", func() {
		CreateVault(cross(cur), other, 30)
	})

	// Interval too long (over 365 days).
	uassert.AbortsContains(t, cur, "too long", func() {
		CreateVault(cross(cur), other, MaxCheckInIntervalSeconds+1)
	})

	// Zero deposit.
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsContains(t, cur, "initial deposit", func() {
		CreateVault(cross(cur), other, 3600)
	})

	// No vaults were created by the failed calls.
	uassert.Equal(t, 0, VaultCount())
}

func TestDeposit(cur realm, t *testing.T) {
	defer resetTestState()
	owner := testutils.TestAddress("owner3")
	beneficiary := testutils.TestAddress("beneficiary3")
	other := testutils.TestAddress("other3")
	id := makeVault(cur, t, owner, beneficiary, 3600, 1000)

	// Owner tops up by 500.
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 500}})
	balance := Deposit(cross(cur), id)
	uassert.Equal(t, int64(1500), balance)
	uassert.Equal(t, int64(1500), GetVault(id).Balance)

	// A non-owner cannot deposit.
	testing.SetRealm(testing.NewUserRealm(other))
	testing.SetOriginSend(chain.Coins{{Denom: Denom, Amount: 500}})
	uassert.AbortsContains(t, cur, "only the vault owner may deposit", func() {
		Deposit(cross(cur), id)
	})
	uassert.Equal(t, int64(1500), GetVault(id).Balance)

	// A zero deposit fails.
	testing.SetRealm(testing.NewUserRealm(owner))
	testing.SetOriginSend(chain.Coins{})
	uassert.AbortsContains(t, cur, "attach ugnot", func() {
		Deposit(cross(cur), id)
	})
}

func TestCheckInResetsTimer(cur realm, t *testing.T) {
	defer resetTestState()
	owner := testutils.TestAddress("owner4")
	beneficiary := testutils.TestAddress("beneficiary4")
	other := testutils.TestAddress("other4")
	id := makeVault(cur, t, owner, beneficiary, 3600, 1000)

	// Simulate a nearly-expired vault, then check in.
	v := mustGetVault(id)
	v.Deadline = time.Now().Add(10 * time.Second)
	vaults.Set("1", v)
	oldDeadline := v.Deadline

	testing.SetRealm(testing.NewUserRealm(owner))
	newDeadline := CheckIn(cross(cur), id)
	uassert.True(t, newDeadline.After(oldDeadline))
	uassert.True(t, newDeadline.Equal(time.Now().Add(3600*time.Second)))
	uassert.Equal(t, "active", GetVault(id).Status())

	// A non-owner cannot check in.
	testing.SetRealm(testing.NewUserRealm(other))
	uassert.AbortsContains(t, cur, "only the vault owner may check in", func() {
		CheckIn(cross(cur), id)
	})

	// Checking in after the deadline is too late.
	v = mustGetVault(id)
	v.Deadline = time.Now().Add(-1 * time.Hour)
	vaults.Set("1", v)
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsContains(t, cur, "too late", func() {
		CheckIn(cross(cur), id)
	})
}

func TestEarlyReleaseFails(cur realm, t *testing.T) {
	defer resetTestState()
	owner := testutils.TestAddress("owner5")
	beneficiary := testutils.TestAddress("beneficiary5")
	keeper := testutils.TestAddress("keeper5")
	id := makeVault(cur, t, owner, beneficiary, 3600, 1000)

	testing.SetRealm(testing.NewUserRealm(keeper))
	uassert.AbortsContains(t, cur, "has not expired yet", func() {
		TriggerRelease(cross(cur), id)
	})
	uassert.Equal(t, "active", GetVault(id).Status())
	uassert.False(t, GetVault(id).Released)
}

func TestExpiredReleaseSplits(cur realm, t *testing.T) {
	defer resetTestState()
	owner := testutils.TestAddress("owner6")
	beneficiary := testutils.TestAddress("beneficiary6")
	keeper := testutils.TestAddress("keeper6")
	id := makeVault(cur, t, owner, beneficiary, 3600, 1000)

	// Fast-forward: move the deadline into the past.
	v := mustGetVault(id)
	v.Deadline = time.Now().Add(-1 * time.Hour)
	vaults.Set("1", v)
	uassert.Equal(t, "expired — awaiting keeper", GetVault(id).Status())

	testing.SetRealm(testing.NewUserRealm(keeper))
	share, fee := TriggerRelease(cross(cur), id)
	uassert.Equal(t, int64(980), share)
	uassert.Equal(t, int64(20), fee)

	// Balances on chain: beneficiary 98%, keeper 2%.
	banker_ := banker.NewReadonlyBanker()
	uassert.Equal(t, int64(980), banker_.GetCoin(beneficiary, Denom))
	uassert.Equal(t, int64(20), banker_.GetCoin(keeper, Denom))

	// Vault is marked released, with the keeper recorded.
	released := GetVault(id)
	uassert.True(t, released.Released)
	uassert.Equal(t, keeper, released.Keeper)
	uassert.Equal(t, "released", released.Status())

	// Double-release fails.
	uassert.AbortsContains(t, cur, "already released", func() {
		TriggerRelease(cross(cur), id)
	})
	// Check-in after release fails too.
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsContains(t, cur, "already released", func() {
		CheckIn(cross(cur), id)
	})
}

func TestKeeperCannotBeOwnerOrBeneficiary(cur realm, t *testing.T) {
	defer resetTestState()
	owner := testutils.TestAddress("owner7")
	beneficiary := testutils.TestAddress("beneficiary7")
	id := makeVault(cur, t, owner, beneficiary, 3600, 1000)

	v := mustGetVault(id)
	v.Deadline = time.Now().Add(-1 * time.Hour)
	vaults.Set("1", v)

	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsContains(t, cur, "owner cannot be the keeper", func() {
		TriggerRelease(cross(cur), id)
	})
	testing.SetRealm(testing.NewUserRealm(beneficiary))
	uassert.AbortsContains(t, cur, "beneficiary cannot be the keeper", func() {
		TriggerRelease(cross(cur), id)
	})
	uassert.False(t, GetVault(id).Released)
}

func TestCancelRefunds(cur realm, t *testing.T) {
	defer resetTestState()
	owner := testutils.TestAddress("owner8")
	beneficiary := testutils.TestAddress("beneficiary8")
	other := testutils.TestAddress("other8")
	id := makeVault(cur, t, owner, beneficiary, 3600, 500)

	// A non-owner cannot cancel.
	testing.SetRealm(testing.NewUserRealm(other))
	uassert.AbortsContains(t, cur, "only the vault owner may cancel", func() {
		Cancel(cross(cur), id)
	})

	// Owner cancels before expiry: full refund.
	testing.SetRealm(testing.NewUserRealm(owner))
	refund := Cancel(cross(cur), id)
	uassert.Equal(t, int64(500), refund)
	banker_ := banker.NewReadonlyBanker()
	uassert.Equal(t, int64(500), banker_.GetCoin(owner, Denom))
	cancelled := GetVault(id)
	uassert.True(t, cancelled.Cancelled)
	uassert.Equal(t, int64(0), cancelled.Balance)
	uassert.Equal(t, "cancelled", cancelled.Status())

	// Nothing more can happen to a cancelled vault.
	// (Call as a third party: as the owner, TriggerRelease would
	// abort on the keeper check first, which is also correct.)
	testing.SetRealm(testing.NewUserRealm(other))
	uassert.AbortsContains(t, cur, "already cancelled", func() {
		TriggerRelease(cross(cur), id)
	})
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsContains(t, cur, "already cancelled", func() {
		CheckIn(cross(cur), id)
	})

	// Cancelling after the deadline is refused: after expiry the
	// funds belong to the beneficiary.
	id2 := makeVault(cur, t, owner, beneficiary, 3600, 500)
	v := mustGetVault(id2)
	v.Deadline = time.Now().Add(-1 * time.Hour)
	vaults.Set("2", v)
	uassert.AbortsContains(t, cur, "no longer be cancelled", func() {
		Cancel(cross(cur), id2)
	})
}

func TestRender(cur realm, t *testing.T) {
	defer resetTestState()
	owner := testutils.TestAddress("owner9")
	beneficiary := testutils.TestAddress("beneficiary9")
	id := makeVault(cur, t, owner, beneficiary, 3600, 1000)

	home := Render("")
	uassert.True(t, strings.Contains(home, "# HeirRealm"))
	uassert.True(t, strings.Contains(home, "Vault #1"))
	uassert.True(t, strings.Contains(home, "active"))

	detail := Render("1")
	uassert.True(t, strings.Contains(detail, "Vault #1"))
	uassert.True(t, strings.Contains(detail, "1000 ugnot"))

	uassert.Equal(t, "# HeirRealm\n\nUnknown vault.", Render("999"))
	_ = id
}
