package kolektif

import (
	"strings"
	"testing"

	"gno.land/p/g1udyt8ywv489087rn5td39m8t3peve3hxjz08w2/kolektif/rosca"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// newFilledCircle creates a circle and seats three members, which activates it.
//
// testing.SetRealm only applies to the frame that calls it, so every seat is
// taken inline here rather than through a shared helper.
func newFilledCircle(cur realm, t *testing.T, contribution int64, span int64) uint64 {
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")

	testing.SetRealm(testing.NewUserRealm(alice))
	id := Create(cross(cur), "Warung Crew", contribution, 3, span)
	if id != 1 {
		t.Fatalf("expected the first circle to be id 1, got %d", id)
	}

	members := []address{alice, bob, carol}
	for _, m := range members {
		testing.SetRealm(testing.NewUserRealm(m))
		payFrom(contribution)
		Join(cross(cur), id)
	}
	return id
}

func TestNoDefaultsEveryMemberNetsZero(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	members := []address{alice, bob, carol}

	start := int64(10) * gnot
	for _, m := range members {
		fund(m, start)
	}

	id := newFilledCircle(cross(cur), t, 1*gnot, 60)
	c := mustCircle(id)

	if c.Status != rosca.StatusActive {
		t.Fatalf("circle should be active after the last seat fills, got %s", c.Status.String())
	}
	if len(c.Order) != 3 {
		t.Fatalf("expected an order of 3, got %d", len(c.Order))
	}
	if c.Pool != 3*gnot {
		t.Fatalf("pool should hold 3 GNOT of collateral, got %d", c.Pool)
	}

	// Three rounds: everyone pays, the last payer releases the pot.
	sent := make(map[address]int64, 3)
	for round := 0; round < 3; round++ {
		for _, m := range members {
			testing.SetRealm(testing.NewUserRealm(m))
			payFrom(1 * gnot)
			Contribute(cross(cur), id)
			sent[m] = sent[m] + 1*gnot
		}
	}
	// The collateral locked at join counts as sent too.
	for _, m := range members {
		sent[m] = sent[m] + 1*gnot
	}

	c = mustCircle(id)
	if c.Status != rosca.StatusComplete {
		t.Fatalf("circle should be complete, got %s", c.Status.String())
	}
	if c.Pool != 0 {
		t.Fatalf("circle pool should be empty at close, got %d", c.Pool)
	}

	// No defaults: what every member received back equals what they paid in.
	// The test harness credits the realm without debiting the member, so the
	// member's balance only moves on payouts: received == balance - funded.
	for _, m := range members {
		received := balanceOf(m) - start
		if received != sent[m] {
			t.Fatalf("member %s should net zero: paid %d, received %d",
				m.String(), sent[m], received)
		}
	}
	if balanceOf(realmAddr) != 0 {
		t.Fatalf("realm should hold nothing after close, holds %d", balanceOf(realmAddr))
	}
	if c.PaidOutTotal != 12*gnot {
		t.Fatalf("expected 12 GNOT paid out (9 in pots + 3 collateral), got %d", c.PaidOutTotal)
	}
	for _, m := range c.Members {
		if !m.Received {
			t.Fatalf("member %s never received the pot", m.Addr.String())
		}
	}
}

func TestDefaultIsSlashedAndRedistributed(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")

	start := int64(10) * gnot
	fund(alice, start)
	fund(bob, start)
	fund(carol, start)

	id := newFilledCircle(cross(cur), t, 1*gnot, 60)
	c := mustCircle(id)

	// Round 0: alice and bob pay, carol does not.
	testing.SetRealm(testing.NewUserRealm(alice))
	payFrom(1 * gnot)
	Contribute(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(bob))
	payFrom(1 * gnot)
	Contribute(cross(cur), id)

	// Let the round deadline pass: SkipHeights moves block time by 5s per block.
	testing.SkipHeights(30)

	testing.SetRealm(testing.NewUserRealm(alice))
	Advance(cross(cur), id)

	c = mustCircle(id)
	carolSeat := c.Member(carol)
	if carolSeat == nil {
		t.Fatalf("carol should stay on the roster, marked defaulted")
	}
	if !carolSeat.Defaulted {
		t.Fatalf("carol should be in default")
	}
	if carolSeat.Collateral != 0 {
		t.Fatalf("defaulted collateral should be slashed, got %d", carolSeat.Collateral)
	}
	if carolSeat.Received {
		t.Fatalf("a defaulted member must not receive a pot")
	}

	// The two honest members keep paying until both have received.
	guard := 0
	for mustCircle(id).Status == rosca.StatusActive {
		guard++
		if guard > 10 {
			t.Fatalf("circle did not close after the default")
		}
		testing.SetRealm(testing.NewUserRealm(alice))
		payFrom(1 * gnot)
		Contribute(cross(cur), id)
		testing.SetRealm(testing.NewUserRealm(bob))
		payFrom(1 * gnot)
		Contribute(cross(cur), id)
	}

	c = mustCircle(id)
	if c.Status != rosca.StatusComplete {
		t.Fatalf("circle should close, got %s", c.Status.String())
	}
	if got := balanceOf(realmAddr); got != 0 {
		t.Fatalf("realm should hold nothing, holds %d", got)
	}
	if got := balanceOf(carol) - start; got != 0 {
		t.Fatalf("carol should receive nothing back, got %d", got)
	}
	if got := balanceOf(alice) - start; got != 2*gnot+gnot+gnot/2 {
		t.Fatalf("alice should get one pot, her collateral and half the penalty = 3.5 GNOT, got %d", got)
	}
	if got := balanceOf(bob) - start; got != 2*gnot+gnot+gnot/2 {
		t.Fatalf("bob should get one pot, his collateral and half the penalty = 3.5 GNOT, got %d", got)
	}
}
func TestCannotPayTwiceInARound(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")
	fund(alice, 10*gnot)

	id := newFilledCircle(cross(cur), t, 1*gnot, 60)

	testing.SetRealm(testing.NewUserRealm(alice))
	payFrom(1 * gnot)
	Contribute(cross(cur), id)

	uassert.AbortsContains(t, cur, "already paid round", func(cur realm) {
		testing.SetRealm(testing.NewUserRealm(alice))
		payFrom(1 * gnot)
		Contribute(cross(cur), id)
	})
}

func TestAdvanceNeedsExpiredDeadline(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")
	fund(alice, 10*gnot)

	id := newFilledCircle(cross(cur), t, 1*gnot, 600)

	uassert.AbortsContains(t, cur, "deadline has not passed", func(cur realm) {
		testing.SetRealm(testing.NewUserRealm(alice))
		Advance(cross(cur), id)
	})
}

func TestLeaveRefundsCollateralBeforeActivation(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")
	start := int64(5) * gnot
	fund(alice, start)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := Create(cross(cur), "Two seats", 1*gnot, 3, 60)

	testing.SetRealm(testing.NewUserRealm(alice))
	payFrom(1 * gnot)
	Join(cross(cur), id)

	if mustCircle(id).Pool != 1*gnot {
		t.Fatalf("collateral should sit in the pool, pool %d", mustCircle(id).Pool)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	Leave(cross(cur), id)

	if got := balanceOf(alice) - start; got != 1*gnot {
		t.Fatalf("leave should return the collateral, got %d", got)
	}
	if mustCircle(id).Seats() != 0 {
		t.Fatalf("seat should be free again")
	}
	if mustCircle(id).Pool != 0 {
		t.Fatalf("pool should be empty, got %d", mustCircle(id).Pool)
	}
}

func TestCancelRefundsEverySeat(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	fund(alice, 5*gnot)
	fund(bob, 5*gnot)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := Create(cross(cur), "Never filled", 1*gnot, 3, 60)

	testing.SetRealm(testing.NewUserRealm(alice))
	payFrom(1 * gnot)
	Join(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(bob))
	payFrom(1 * gnot)
	Join(cross(cur), id)

	testing.SetRealm(testing.NewUserRealm(alice))
	Cancel(cross(cur), id)

	c := mustCircle(id)
	if got := balanceOf(alice) - 5*gnot; got != 1*gnot {
		t.Fatalf("alice should be refunded, got %d", got)
	}
	if got := balanceOf(bob) - 5*gnot; got != 1*gnot {
		t.Fatalf("bob should be refunded, got %d", got)
	}
	if !c.Cancelled || c.Status != rosca.StatusComplete {
		t.Fatalf("circle should be cancelled and closed")
	}
	if c.Pool != 0 {
		t.Fatalf("pool should be empty after cancel, got %d", c.Pool)
	}
}

func TestOnlyCreatorCanCancel(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	fund(alice, 5*gnot)
	fund(bob, 5*gnot)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := Create(cross(cur), "Guarded", 1*gnot, 3, 60)

	uassert.AbortsContains(t, cur, "only the creator", func(cur realm) {
		testing.SetRealm(testing.NewUserRealm(bob))
		Cancel(cross(cur), id)
	})
}

func TestJoinNeedsExactCollateral(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")
	fund(alice, 5*gnot)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := Create(cross(cur), "Exact", 1*gnot, 3, 60)

	uassert.AbortsContains(t, cur, "must be exactly", func(cur realm) {
		testing.SetRealm(testing.NewUserRealm(alice))
		payFrom(2 * gnot)
		Join(cross(cur), id)
	})
}

func TestUnknownCirclePanics(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")

	uassert.AbortsContains(t, cur, "unknown circle", func(cur realm) {
		testing.SetRealm(testing.NewUserRealm(alice))
		Contribute(cross(cur), 42)
	})
}

func TestCreateRejectsBadParameters(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")

	uassert.AbortsContains(t, cur, "size must be between", func(cur realm) {
		testing.SetRealm(testing.NewUserRealm(alice))
		Create(cross(cur), "Too small", 1*gnot, 2, 60)
	})
}

func TestRenderNeverPanicsAndShowsState(cur realm, t *testing.T) {
	reset()
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	carol := testutils.TestAddress("carol")
	for _, m := range []address{alice, bob, carol} {
		fund(m, 10*gnot)
	}

	id := newFilledCircle(cross(cur), t, 1*gnot, 60)

	testing.SetRealm(testing.NewUserRealm(alice))
	payFrom(1 * gnot)
	Contribute(cross(cur), id)

	pages := map[string]string{
		"index":   Render(""),
		"circle":  Render("circle/1"),
		"rules":   Render("circle/1/rules"),
		"about":   Render("about"),
		"member":  Render("member/" + alice.String()),
		"missing": Render("nope"),
	}

	if !strings.Contains(pages["index"], "# Kolektif") {
		t.Fatalf("index should carry the title")
	}
	if !strings.Contains(pages["index"], "Warung Crew") {
		t.Fatalf("index should list the circle")
	}
	if !strings.Contains(pages["circle"], "ACTIVE") {
		t.Fatalf("circle page should show the status")
	}
	if !strings.Contains(pages["circle"], "Members") {
		t.Fatalf("circle page should render the member table")
	}
	if !strings.Contains(pages["rules"], "Fisher-Yates") {
		t.Fatalf("rules page should explain the schedule")
	}
	if !strings.Contains(pages["missing"], "Not found") {
		t.Fatalf("unknown path should render a not-found page")
	}
	for name, page := range pages {
		if len(page) < 40 {
			t.Fatalf("%s page looks empty: %q", name, page)
		}
	}
}
