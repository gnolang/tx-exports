package arisan

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	alice   = testutils.TestAddress("alice")
	bob     = testutils.TestAddress("bob")
	charlie = testutils.TestAddress("charlie")
	dave    = testutils.TestAddress("dave")
)

// newStartedCircle creates a 3-member circle (alice, bob, charlie) with a
// 100000 ugnot contribution and starts it, using the internal
// implementations so no transaction envelope is involved.
func newStartedCircle(t *testing.T) *Circle {
	id := createCircle(alice, "Test Circle", 100_000, 3)
	joinCircle(bob, id)
	joinCircle(charlie, id)
	startCircle(alice, id)

	c := getCircle(id)
	uassert.Equal(t, statusActive, c.status)
	uassert.Equal(t, 3, len(c.members))
	return c
}

func TestCreateCircleValidation(cur realm, t *testing.T) {
	uassert.PanicsContains(t, cur, "arisan:", func() { createCircle(alice, "", 100_000, 3) })
	uassert.PanicsContains(t, cur, "arisan:", func() { createCircle(alice, "Bad [Name]", 100_000, 3) })
	uassert.PanicsContains(t, cur, "arisan:", func() { createCircle(alice, "x", 999, 3) })
	uassert.PanicsContains(t, cur, "arisan:", func() { createCircle(alice, "x", 100_000, 1) })
	uassert.PanicsContains(t, cur, "arisan:", func() { createCircle(alice, "x", 100_000, 13) })

	before := CircleCount()
	id := createCircle(alice, "Keluarga", 50_000, 4)
	uassert.Equal(t, before+1, CircleCount())

	c := getCircle(id)
	uassert.Equal(t, statusOpen, c.status)
	uassert.Equal(t, alice, c.creator)
	uassert.Equal(t, 1, len(c.members))
	uassert.Equal(t, int64(50_000), c.contribution)
}

func TestJoinAndStartGuards(cur realm, t *testing.T) {
	id := createCircle(alice, "Guards", 100_000, 2)

	// Creator is already a member.
	uassert.PanicsContains(t, cur, "arisan:", func() { joinCircle(alice, id) })
	// Non-creator cannot start.
	uassert.PanicsContains(t, cur, "arisan:", func() { startCircle(bob, id) })
	// Creator cannot start with a single member.
	uassert.PanicsContains(t, cur, "arisan:", func() { startCircle(alice, id) })

	joinCircle(bob, id)

	// Circle is full now.
	uassert.PanicsContains(t, cur, "arisan:", func() { joinCircle(charlie, id) })

	startCircle(alice, id)
	uassert.Equal(t, statusActive, getCircle(id).status)

	// Joining after start is closed.
	uassert.PanicsContains(t, cur, "arisan:", func() { joinCircle(charlie, id) })
}

func TestCancelCircle(cur realm, t *testing.T) {
	id := createCircle(alice, "Cancel Me", 100_000, 3)

	uassert.PanicsContains(t, cur, "arisan:", func() { cancelCircle(bob, id) })

	cancelCircle(alice, id)
	uassert.Equal(t, statusCancelled, getCircle(id).status)
}

func TestContributeGuards(cur realm, t *testing.T) {
	c := newStartedCircle(t)

	// Non-member cannot contribute.
	uassert.PanicsContains(t, cur, "arisan:", func() { contribute(cur, c, dave, 100_000) })
	// Wrong amount is rejected.
	uassert.PanicsContains(t, cur, "arisan:", func() { contribute(cur, c, alice, 99_999) })
	uassert.PanicsContains(t, cur, "arisan:", func() { contribute(cur, c, alice, 0) })

	// A valid contribution is recorded, and a second one is rejected.
	contribute(cur, c, alice, 100_000)
	uassert.True(t, c.paid[alice])
	uassert.PanicsContains(t, cur, "arisan:", func() { contribute(cur, c, alice, 100_000) })
}

func TestFullLifecycle(cur realm, t *testing.T) {
	c := newStartedCircle(t)
	members := []address{alice, bob, charlie}

	// The internal contribute() calls in this test move no real coins, so
	// pre-fund the realm's account with the total of all three pots
	// (3 rounds x 3 members x 100000 ugnot) for the payouts to draw on.
	realmAddr := chain.PackageAddress("gno.land/r/g1ulwmlzxtx922c7r8asp6ux23ks8rw6r8m2uftg/arisan")
	testing.IssueCoins(realmAddr, chain.Coins{{"ugnot", 900_000}})

	// Play all three rounds. Recipients must rotate in join order, and the
	// circle must finish exactly when everyone has received the pot once.
	for round := 0; round < 3; round++ {
		uassert.Equal(t, round, c.round)
		uassert.Equal(t, members[round], nextRecipient(c))
		for _, m := range members {
			contribute(cur, c, m, 100_000)
		}
		uassert.Equal(t, round+1, len(c.payouts))
		uassert.Equal(t, members[round], c.payouts[round])
	}
	uassert.Equal(t, statusFinished, c.status)

	// A finished circle takes no more contributions.
	uassert.PanicsContains(t, cur, "arisan:", func() { contribute(cur, c, alice, 100_000) })
}

func TestRender(cur realm, t *testing.T) {
	c := newStartedCircle(t)

	home := Render("")
	uassert.True(t, len(home) > 0)
	uassert.True(t, contains(home, "Test Circle"))

	page := Render("circle/" + itoa(c.id))
	uassert.True(t, contains(page, "Test Circle"))
	uassert.True(t, contains(page, "Round 1 of 3"))

	uassert.True(t, contains(Render("circle/99999"), "not found"))
	uassert.True(t, contains(Render("nonsense"), "not found"))
}

// TestCrossingEntryPoints exercises the real transaction-facing functions
// the way gnokey calls them, with the caller simulated by the test
// framework's user realms.
func TestCrossingEntryPoints(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateCircle(cross(cur), "Crossing", 100_000, 2)

	testing.SetRealm(testing.NewUserRealm(bob))
	JoinCircle(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(alice))
	StartCircle(cross(cur), id)

	uassert.Equal(t, statusActive, getCircle(id).status)
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	return digits
}
