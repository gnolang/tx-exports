package agentleash

import (
	"chain"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	owner = testutils.TestAddress("owner")
	agent = testutils.TestAddress("agent")
	payee = testutils.TestAddress("payee")
)

const (
	perTx = int64(100_000) // 0.1 GNOT
	daily = int64(250_000) // 0.25 GNOT
)

// setup creates a leash as owner and deposits 500_000 ugnot into it.
// The realm is pre-funded with IssueCoins so Spend/Revoke payouts succeed.
func setup(cur realm, t *testing.T) int {
	t.Helper()
	pkgAddr := chain.PackageAddress("gno.land/r/agentleash/agentleash")
	testing.IssueCoins(pkgAddr, chain.Coins{{"ugnot", 100_000_000}})

	testing.SetRealm(testing.NewUserRealm(owner))
	id := CreateLeash(cross(cur), agent, perTx, daily, 0)
	testing.SetOriginSend(chain.Coins{{"ugnot", 500_000}})
	Deposit(cross(cur), id)
	return id
}

func TestCreateAndDeposit(cur realm, t *testing.T) {
	defer resetTestState()
	id := setup(cur, t)

	l := mustGet(id)
	uassert.Equal(t, owner, l.Owner)
	uassert.Equal(t, agent, l.Agent)
	uassert.Equal(t, perTx, l.PerTxCap)
	uassert.Equal(t, daily, l.DailyCap)
	uassert.Equal(t, int64(500_000), l.Balance)
	uassert.Equal(t, "active", l.status())
}

func TestSpendWithinCaps(cur realm, t *testing.T) {
	defer resetTestState()
	id := setup(cur, t)

	testing.SetRealm(testing.NewUserRealm(agent))
	Spend(cross(cur), id, payee, perTx, "invoice #1")

	l := mustGet(id)
	uassert.Equal(t, int64(400_000), l.Balance)
	uassert.Equal(t, perTx, l.SpentToday)
	uassert.Equal(t, 1, len(l.History))
	uassert.Equal(t, payee, l.History[0].To)
	uassert.Equal(t, perTx, l.History[0].Amount)
}

func TestSpendOverPerTxCap(cur realm, t *testing.T) {
	defer resetTestState()
	id := setup(cur, t)

	testing.SetRealm(testing.NewUserRealm(agent))
	uassert.AbortsWithMessage(t, cur, "over per-transaction cap", func() {
		Spend(cross(cur), id, payee, perTx+1, "too much")
	})

	l := mustGet(id)
	uassert.Equal(t, int64(500_000), l.Balance) // unchanged
	uassert.Equal(t, int64(0), l.SpentToday)
	uassert.Equal(t, 0, len(l.History))
}

func TestSpendOverDailyCap(cur realm, t *testing.T) {
	defer resetTestState()
	id := setup(cur, t)

	testing.SetRealm(testing.NewUserRealm(agent))
	Spend(cross(cur), id, payee, perTx, "one")
	Spend(cross(cur), id, payee, perTx, "two")
	// 200_000 spent; one more 60_000 stays under the per-tx cap but
	// pushes the day total to 260_000 > 250_000 daily cap.
	uassert.AbortsWithMessage(t, cur, "over daily cap", func() {
		Spend(cross(cur), id, payee, 60_000, "three")
	})

	l := mustGet(id)
	uassert.Equal(t, int64(200_000), l.SpentToday)
	uassert.Equal(t, 2, len(l.History))
}

func TestSpendWrongCaller(cur realm, t *testing.T) {
	defer resetTestState()
	id := setup(cur, t)

	// The owner is not the agent: even the owner cannot spend.
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsWithMessage(t, cur, "caller is not the agent", func() {
		Spend(cross(cur), id, payee, 1_000, "owner trying")
	})
}

func TestPauseBlocksSpend(cur realm, t *testing.T) {
	defer resetTestState()
	id := setup(cur, t)

	testing.SetRealm(testing.NewUserRealm(owner))
	PauseLeash(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(agent))
	uassert.AbortsWithMessage(t, cur, "leash is paused", func() {
		Spend(cross(cur), id, payee, 1_000, "while paused")
	})

	testing.SetRealm(testing.NewUserRealm(owner))
	ResumeLeash(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(agent))
	Spend(cross(cur), id, payee, 1_000, "after resume")
	uassert.Equal(t, int64(499_000), mustGet(id).Balance)
}

func TestRevokeRefundsAndLocks(cur realm, t *testing.T) {
	defer resetTestState()
	id := setup(cur, t)

	testing.SetRealm(testing.NewUserRealm(agent))
	Spend(cross(cur), id, payee, perTx, "before revoke")

	testing.SetRealm(testing.NewUserRealm(owner))
	RevokeLeash(cross(cur), id)

	l := mustGet(id)
	uassert.True(t, l.Revoked)
	uassert.Equal(t, int64(0), l.Balance) // remainder refunded to owner

	testing.SetRealm(testing.NewUserRealm(agent))
	uassert.AbortsWithMessage(t, cur, "leash is revoked", func() {
		Spend(cross(cur), id, payee, 1_000, "after revoke")
	})
}

func resetTestState() {
	leashes = avl.Tree{}
	counter = 0
}
