package arisan

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

const testRealmPath = "gno.land/r/g1u9frcg00ncx6ws8h6whtkdg2z4gsv0hjvzh20w/arisan"

func resetTestState() {
	circles = avl.Tree{}
	nextID = 0
}

func testAddrs() (organizer, m1, m2, m3 address) {
	return testutils.TestAddress("organizer"),
		testutils.TestAddress("member1"),
		testutils.TestAddress("member2"),
		testutils.TestAddress("member3")
}

// setupCircle creates a circle with 3 members and starts round 1.
// Contribution is 1000 ugnot, max 4 members.
func setupCircle(cur realm, t *testing.T) (int, address, address, address, address) {
	org, m1, m2, m3 := testAddrs()
	testing.SetRealm(testing.NewUserRealm(org))
	id := CreateCircle(cross(cur), "Arisan RT 05", 1000, 4)
	uassert.Equal(t, 1, id)
	testing.SetRealm(testing.NewUserRealm(m1))
	JoinCircle(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(m2))
	JoinCircle(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(m3))
	JoinCircle(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(org))
	StartCircle(cross(cur), id)
	return id, org, m1, m2, m3
}

func depositAs(cur realm, who address, id int, amount int64) {
	testing.SetRealm(testing.NewUserRealm(who))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: amount}})
	Deposit(cross(cur), id)
}

func TestCreateCircle(cur realm, t *testing.T) {
	defer resetTestState()
	org, _, _, _ := testAddrs()
	testing.SetRealm(testing.NewUserRealm(org))
	id := CreateCircle(cross(cur), "Arisan RT 05", 1000, 4)
	uassert.Equal(t, 1, id)
	c := mustGetCircle(id)
	uassert.Equal(t, "Arisan RT 05", c.Name)
	uassert.Equal(t, org, c.Organizer)
	uassert.Equal(t, int64(1000), c.Contribution)
	uassert.Equal(t, 4, c.MaxMembers)
	uassert.False(t, c.Started)
	uassert.Equal(t, 0, c.Round)
	uassert.Equal(t, 1, CircleCount())

	// Invalid creates abort.
	uassert.AbortsWithMessage(t, cur, "circle name must not be empty", func() {
		CreateCircle(cross(cur), "", 1000, 4)
	})
	uassert.AbortsWithMessage(t, cur, "contribution must be positive (ugnot)", func() {
		CreateCircle(cross(cur), "X", 0, 4)
	})
	uassert.AbortsWithMessage(t, cur, "a circle needs at least 2 members", func() {
		CreateCircle(cross(cur), "X", 1000, 1)
	})
}

func TestJoinAndStart(cur realm, t *testing.T) {
	defer resetTestState()
	org, m1, m2, m3 := testAddrs()
	testing.SetRealm(testing.NewUserRealm(org))
	id := CreateCircle(cross(cur), "Arisan RT 05", 1000, 4)

	// Only the organizer can start.
	testing.SetRealm(testing.NewUserRealm(m1))
	uassert.AbortsWithMessage(t, cur, "only the organizer can start the circle", func() {
		StartCircle(cross(cur), id)
	})
	// Cannot start with fewer than 2 members.
	testing.SetRealm(testing.NewUserRealm(org))
	uassert.AbortsWithMessage(t, cur, "need at least 2 members to start", func() {
		StartCircle(cross(cur), id)
	})

	testing.SetRealm(testing.NewUserRealm(m1))
	JoinCircle(cross(cur), id)
	// Duplicate join aborts.
	uassert.AbortsWithMessage(t, cur, "already a member of this circle", func() {
		JoinCircle(cross(cur), id)
	})
	testing.SetRealm(testing.NewUserRealm(m2))
	JoinCircle(cross(cur), id)
	testing.SetRealm(testing.NewUserRealm(m3))
	JoinCircle(cross(cur), id)

	c := mustGetCircle(id)
	uassert.Equal(t, 3, len(c.Members))
	// Join order is rotation order.
	uassert.Equal(t, m1, c.Members[0])
	uassert.Equal(t, m2, c.Members[1])
	uassert.Equal(t, m3, c.Members[2])

	testing.SetRealm(testing.NewUserRealm(org))
	StartCircle(cross(cur), id)
	c = mustGetCircle(id)
	uassert.True(t, c.Started)
	uassert.Equal(t, 1, c.Round)

	// Joining after start aborts.
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("latecomer")))
	uassert.AbortsWithMessage(t, cur, "circle already started; joining is closed", func() {
		JoinCircle(cross(cur), id)
	})
}

func TestDepositRules(cur realm, t *testing.T) {
	defer resetTestState()
	id, org, m1, m2, m3 := setupCircle(cur, t)
	_ = org
	_ = m2
	_ = m3

	// Non-member cannot deposit.
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("outsider")))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1000}})
	uassert.AbortsWithMessage(t, cur, "only members can deposit", func() {
		Deposit(cross(cur), id)
	})

	// Wrong amount aborts.
	testing.SetRealm(testing.NewUserRealm(m1))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 999}})
	uassert.AbortsWithMessage(t, cur, "send exactly the contribution amount", func() {
		Deposit(cross(cur), id)
	})
	// Wrong denom aborts.
	testing.SetOriginSend(chain.Coins{{Denom: "atom", Amount: 1000}})
	uassert.AbortsWithMessage(t, cur, "contribution must be paid in ugnot", func() {
		Deposit(cross(cur), id)
	})

	// Correct deposit works.
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1000}})
	Deposit(cross(cur), id)
	c := mustGetCircle(id)
	uassert.True(t, c.Paid[0])
	uassert.Equal(t, int64(1000), c.Pot)
	uassert.Equal(t, 1, c.PaidCount[0])

	// Double deposit in the same round aborts.
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1000}})
	uassert.AbortsWithMessage(t, cur, "already paid for this round", func() {
		Deposit(cross(cur), id)
	})
}

func TestAdvanceFullRound(cur realm, t *testing.T) {
	defer resetTestState()
	// Fund the realm so payouts have a balance to draw from in the test VM.
	pkgAddr := chain.PackageAddress(testRealmPath)
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: "ugnot", Amount: 100000000}})
	rb := banker.NewReadonlyBanker()

	id, org, m1, m2, m3 := setupCircle(cur, t)

	// Advance before everyone paid aborts.
	testing.SetRealm(testing.NewUserRealm(org))
	uassert.AbortsWithMessage(t, cur, "not all members have paid for this round", func() {
		AdvanceRound(cross(cur), id)
	})
	// Advance by a non-organizer aborts (even after all paid, checked below).
	depositAs(cur, m1, id, 1000)
	depositAs(cur, m2, id, 1000)
	testing.SetRealm(testing.NewUserRealm(m1))
	uassert.AbortsWithMessage(t, cur, "only the organizer can advance the round", func() {
		AdvanceRound(cross(cur), id)
	})
	depositAs(cur, m3, id, 1000)

	c := mustGetCircle(id)
	uassert.Equal(t, int64(3000), c.Pot)

	// Round 1: turn-taker is m1 (first to join).
	testing.SetRealm(testing.NewUserRealm(org))
	AdvanceRound(cross(cur), id)
	uassert.Equal(t, int64(3000), rb.GetCoin(m1, "ugnot"))
	uassert.Equal(t, int64(0), rb.GetCoin(m2, "ugnot"))
	uassert.Equal(t, int64(0), rb.GetCoin(m3, "ugnot"))
	c = mustGetCircle(id)
	uassert.Equal(t, 2, c.Round)
	uassert.Equal(t, int64(0), c.Pot)
	uassert.Equal(t, int64(3000), c.TotalPaidOut)
	uassert.Equal(t, 1, c.TurnsTaken[0])
	uassert.False(t, c.Paid[0])
	uassert.False(t, c.Paid[1])
	uassert.False(t, c.Paid[2])

	// Round 2: turn-taker is m2.
	depositAs(cur, m1, id, 1000)
	depositAs(cur, m2, id, 1000)
	depositAs(cur, m3, id, 1000)
	testing.SetRealm(testing.NewUserRealm(org))
	AdvanceRound(cross(cur), id)
	uassert.Equal(t, int64(3000), rb.GetCoin(m2, "ugnot"))
	uassert.Equal(t, int64(3000), rb.GetCoin(m1, "ugnot"))
	c = mustGetCircle(id)
	uassert.Equal(t, 3, c.Round)
	uassert.Equal(t, int64(6000), c.TotalPaidOut)
	uassert.Equal(t, 1, c.TurnsTaken[1])

	// Round 3: turn-taker is m3.
	depositAs(cur, m1, id, 1000)
	depositAs(cur, m2, id, 1000)
	depositAs(cur, m3, id, 1000)
	testing.SetRealm(testing.NewUserRealm(org))
	AdvanceRound(cross(cur), id)
	uassert.Equal(t, int64(3000), rb.GetCoin(m3, "ugnot"))
	c = mustGetCircle(id)
	uassert.Equal(t, 4, c.Round)
	uassert.Equal(t, int64(9000), c.TotalPaidOut)

	// Round 4 wraps around: turn-taker is m1 again.
	depositAs(cur, m1, id, 1000)
	depositAs(cur, m2, id, 1000)
	depositAs(cur, m3, id, 1000)
	testing.SetRealm(testing.NewUserRealm(org))
	AdvanceRound(cross(cur), id)
	uassert.Equal(t, int64(6000), rb.GetCoin(m1, "ugnot"))
	c = mustGetCircle(id)
	uassert.Equal(t, 2, c.TurnsTaken[0])
}

func TestTwoCirclesIndependent(cur realm, t *testing.T) {
	defer resetTestState()
	pkgAddr := chain.PackageAddress(testRealmPath)
	testing.IssueCoins(pkgAddr, chain.Coins{{Denom: "ugnot", Amount: 100000000}})
	org, m1, m2, m3 := testAddrs()

	testing.SetRealm(testing.NewUserRealm(org))
	id1 := CreateCircle(cross(cur), "Circle Satu", 1000, 4)
	id2 := CreateCircle(cross(cur), "Circle Dua", 500, 4)
	uassert.Equal(t, 2, CircleCount())

	testing.SetRealm(testing.NewUserRealm(m1))
	JoinCircle(cross(cur), id1)
	JoinCircle(cross(cur), id2)
	testing.SetRealm(testing.NewUserRealm(m2))
	JoinCircle(cross(cur), id1)
	JoinCircle(cross(cur), id2)
	testing.SetRealm(testing.NewUserRealm(org))
	StartCircle(cross(cur), id1)
	StartCircle(cross(cur), id2)

	// Deposit only in circle 1.
	depositAs(cur, m1, id1, 1000)
	depositAs(cur, m2, id1, 1000)
	c1 := mustGetCircle(id1)
	c2 := mustGetCircle(id2)
	uassert.Equal(t, int64(2000), c1.Pot)
	uassert.Equal(t, int64(0), c2.Pot)

	// Advance circle 1; circle 2 untouched.
	testing.SetRealm(testing.NewUserRealm(org))
	AdvanceRound(cross(cur), id1)
	c1 = mustGetCircle(id1)
	c2 = mustGetCircle(id2)
	uassert.Equal(t, 2, c1.Round)
	uassert.Equal(t, 1, c2.Round)
	uassert.Equal(t, int64(0), c2.Pot)
	_ = m3
}

func TestRender(cur realm, t *testing.T) {
	defer resetTestState()
	id, org, m1, _, _ := setupCircle(cur, t)
	_ = org
	out := Render("")
	uassert.True(t, len(out) > 0, "overview render must not be empty")
	detail := Render("/1")
	uassert.True(t, len(detail) > 0, "detail render must not be empty")
	// Member address appears in the detail view.
	uassert.True(t, containsStr(detail, m1.String()), "detail must list member 1")
	// Before any deposit, members show as BELUM BAYAR.
	uassert.True(t, containsStr(detail, "BELUM BAYAR"), "unpaid members must be flagged")
	// After m1 deposits, the flag flips for m1.
	depositAs(cur, m1, id, 1000)
	detail = Render("/1")
	uassert.True(t, containsStr(detail, "SUDAH BAYAR"), "paid member must show SUDAH BAYAR")
	uassert.True(t, containsStr(detail, "GILIRAN ROUND INI"), "turn-taker must be marked")
	// Unknown circle renders 404.
	uassert.Equal(t, "404: circle tidak ditemukan", Render("/99"))
}

func containsStr(haystack, needle string) bool {
	if len(needle) == 0 {
		return true
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}
