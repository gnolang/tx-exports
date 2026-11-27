package gnomesaver

import (
	"chain"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func resetState() {
	spendable = map[address]int64{}
	savings = map[address]int64{}
	unlockAt = map[address]int64{}
	seen = map[address]bool{}
	depositors = []address{}
	totalSaved = 0
	totalSpend = 0
	totalDep = 0
}

// fundRealm gives the realm real ugnot in the test VM, so withdrawals
// (banker.SendCoins) have a balance to send from. Deposit accounting
// itself only reads the OriginSend envelope.
func fundRealm() {
	testing.IssueCoins(chain.PackageAddress(pkgPath), chain.Coins{{Denom: "ugnot", Amount: 1000000000}})
}

func TestSplit(t *testing.T) {
	saved, spend := split(10000)
	uassert.Equal(t, int64(1000), saved)
	uassert.Equal(t, int64(9000), spend)

	saved, spend = split(1000)
	uassert.Equal(t, int64(100), saved)
	uassert.Equal(t, int64(900), spend)

	saved, spend = split(1005)
	uassert.Equal(t, int64(100), saved)
	uassert.Equal(t, int64(905), spend)
}

func TestDepositSplits90_10(cur realm, t *testing.T) {
	defer resetState()
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 10000}})

	saved, spend := Deposit(cross(cur), 7)
	uassert.Equal(t, int64(1000), saved)
	uassert.Equal(t, int64(9000), spend)

	sp, sv := BalanceOf(alice)
	uassert.Equal(t, int64(9000), sp)
	uassert.Equal(t, int64(1000), sv)

	dep, totSaved, totSpend, users := Stats()
	uassert.Equal(t, int64(1), dep)
	uassert.Equal(t, int64(1000), totSaved)
	uassert.Equal(t, int64(9000), totSpend)
	uassert.Equal(t, 1, users)

	// Unlock is ~7 days out.
	now := time.Now().Unix()
	u := UnlockAt(alice)
	uassert.True(t, u >= now+6*86400 && u <= now+8*86400)
}

func TestDepositBelowMinimumAborts(cur realm, t *testing.T) {
	defer resetState()
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 999}})

	uassert.AbortsWithMessage(t, cur, "deposit below minimum (1000 ugnot)", func() {
		Deposit(cross(cur), 7)
	})
}

func TestDepositBadLockDaysAborts(cur realm, t *testing.T) {
	defer resetState()
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 10000}})

	uassert.AbortsWithMessage(t, cur, "lockDays must be 0-365", func() {
		Deposit(cross(cur), 366)
	})
}

func TestWithdrawSpendableAnytime(cur realm, t *testing.T) {
	defer resetState()
	fundRealm()
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 10000}})
	Deposit(cross(cur), 7)

	WithdrawSpendable(cross(cur), 4000)
	sp, sv := BalanceOf(alice)
	uassert.Equal(t, int64(5000), sp)
	uassert.Equal(t, int64(1000), sv)

	// Overdraw aborts.
	uassert.AbortsWithMessage(t, cur, "insufficient spendable balance", func() {
		WithdrawSpendable(cross(cur), 5001)
	})
}

func TestWithdrawSavingsLockedThenUnlocked(cur realm, t *testing.T) {
	defer resetState()
	fundRealm()
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 10000}})
	Deposit(cross(cur), 7)

	// Still locked: abort.
	uassert.AbortsWithMessage(t, cur, "savings still locked", func() {
		WithdrawSavings(cross(cur), 500)
	})

	// Simulate time passing by moving the unlock into the past.
	unlockAt[alice] = time.Now().Unix() - 1
	WithdrawSavings(cross(cur), 500)
	sp, sv := BalanceOf(alice)
	uassert.Equal(t, int64(9000), sp)
	uassert.Equal(t, int64(500), sv)
}

func TestSecondDepositExtendsLockOnly(cur realm, t *testing.T) {
	defer resetState()
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 10000}})
	Deposit(cross(cur), 30)
	firstUnlock := UnlockAt(alice)

	// A shorter second lock must not shorten the unlock.
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 10000}})
	Deposit(cross(cur), 7)
	uassert.Equal(t, firstUnlock, UnlockAt(alice))

	sp, sv := BalanceOf(alice)
	uassert.Equal(t, int64(18000), sp)
	uassert.Equal(t, int64(2000), sv)
}

func TestLeaderboard(cur realm, t *testing.T) {
	defer resetState()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 10000}})
	Deposit(cross(cur), 7)

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 50000}})
	Deposit(cross(cur), 7)

	lb := Leaderboard()
	// Bob (5000 saved) must rank above Alice (1000 saved).
	bi := indexOf(lb, bob.String())
	ai := indexOf(lb, alice.String())
	uassert.True(t, bi >= 0 && ai >= 0 && bi < ai)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
