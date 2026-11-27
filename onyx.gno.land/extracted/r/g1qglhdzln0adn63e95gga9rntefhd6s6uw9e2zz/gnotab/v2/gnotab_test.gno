package gnotab

import (
	"testing"
)

// Throwaway test addresses (keys generated locally with gnokey, test-only).
var (
	alice = address("g13guqfpf95vd5758ak8udtywk23hrzmf5yfq38a")
	bob   = address("g15m8vpgr56wvk8vtwh4xfecw7pdnansccwhfw25")
	carol = address("g1324d550z3pregw3njlfhfcwr353rcyhp96hkmx")
)

func TestCreateGroup(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateGroup(cross(cur), "Tavern Night", bob.String() + "," + carol.String())
	if id <= 0 {
		t.Fatalf("expected positive group id, got %d", id)
	}
	g := getGroup(id)
	if len(g.Members) != 3 {
		t.Fatalf("expected 3 members, got %d", len(g.Members))
	}
	if g.Members[0] != alice || g.Members[1] != bob || g.Members[2] != carol {
		t.Fatalf("unexpected member order: %v", g.Members)
	}
	for _, m := range g.Members {
		if g.Balances[m] != 0 {
			t.Fatalf("expected zero starting balance for %s, got %d", m, g.Balances[m])
		}
	}
}

func TestSplitThreeWays(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateGroup(cross(cur), "Dinner", bob.String() + "," + carol.String())

	// Alice pays 900000 ugnot (0.9 GNOT), split evenly among all three.
	expID := AddExpense(cross(cur), id, 900000, alice.String() + "," + bob.String() + "," + carol.String(), "dinner")
	if expID != 1 {
		t.Fatalf("expected expense id 1, got %d", expID)
	}
	if got := GetBalance(id, alice); got != 600000 {
		t.Fatalf("alice balance: expected 600000, got %d", got)
	}
	if got := GetBalance(id, bob); got != -300000 {
		t.Fatalf("bob balance: expected -300000, got %d", got)
	}
	if got := GetBalance(id, carol); got != -300000 {
		t.Fatalf("carol balance: expected -300000, got %d", got)
	}

	// Netted transfers: bob -> alice 300000, carol -> alice 300000.
	trs := computeTransfers(getGroup(id))
	if len(trs) != 2 {
		t.Fatalf("expected 2 netted transfers, got %d", len(trs))
	}
	if trs[0].From != bob || trs[0].To != alice || trs[0].Amount != 300000 {
		t.Fatalf("unexpected transfer 0: %+v", trs[0])
	}
	if trs[1].From != carol || trs[1].To != alice || trs[1].Amount != 300000 {
		t.Fatalf("unexpected transfer 1: %+v", trs[1])
	}
}

func TestNettingTwoWay(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateGroup(cross(cur), "Two Way", bob.String())

	// Alice pays 300 for both: alice +150, bob -150.
	AddExpense(cross(cur), id, 300, alice.String() + "," + bob.String(), "round 1")
	// Bob pays 100 for both: bob +50, alice -50.
	testing.SetRealm(testing.NewUserRealm(bob))
	AddExpense(cross(cur), id, 100, alice.String() + "," + bob.String(), "round 2")

	// Net: alice +100, bob -100 (the two debts net against each other).
	if got := GetBalance(id, alice); got != 100 {
		t.Fatalf("alice balance: expected 100, got %d", got)
	}
	if got := GetBalance(id, bob); got != -100 {
		t.Fatalf("bob balance: expected -100, got %d", got)
	}
	trs := computeTransfers(getGroup(id))
	if len(trs) != 1 {
		t.Fatalf("expected 1 netted transfer, got %d", len(trs))
	}
	if trs[0].From != bob || trs[0].To != alice || trs[0].Amount != 100 {
		t.Fatalf("unexpected transfer: %+v", trs[0])
	}
}

func TestSettlePaysOff(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateGroup(cross(cur), "Settle Up", bob.String() + "," + carol.String())

	// Alice pays 900 split three ways: bob and carol each owe alice 300.
	AddExpense(cross(cur), id, 900, alice.String() + "," + bob.String() + "," + carol.String(), "tab")

	// Bob settles his full 300 with alice.
	testing.SetRealm(testing.NewUserRealm(bob))
	Settle(cross(cur), id, alice, 300)
	if got := GetBalance(id, bob); got != 0 {
		t.Fatalf("bob balance after settle: expected 0, got %d", got)
	}
	if got := GetBalance(id, alice); got != 300 {
		t.Fatalf("alice balance after bob settles: expected 300, got %d", got)
	}

	// Carol settles hers too; everyone ends at zero.
	testing.SetRealm(testing.NewUserRealm(carol))
	Settle(cross(cur), id, alice, 300)
	for _, m := range []address{alice, bob, carol} {
		if got := GetBalance(id, m); got != 0 {
			t.Fatalf("balance of %s: expected 0, got %d", m, got)
		}
	}
	if trs := computeTransfers(getGroup(id)); len(trs) != 0 {
		t.Fatalf("expected no transfers after full settlement, got %d", len(trs))
	}
	if n := len(getGroup(id).Settlements); n != 2 {
		t.Fatalf("expected 2 recorded settlements, got %d", n)
	}
}

func TestSplitRemainder(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateGroup(cross(cur), "Remainder", bob.String() + "," + carol.String())

	// 100 ugnot split 3 ways: shares 34/33/33 (remainder to first listed).
	AddExpense(cross(cur), id, 100, alice.String() + "," + bob.String() + "," + carol.String(), "odd amount")
	if got := GetBalance(id, alice); got != 100-34 {
		t.Fatalf("alice balance: expected 66, got %d", got)
	}
	if got := GetBalance(id, bob); got != -33 {
		t.Fatalf("bob balance: expected -33, got %d", got)
	}
	if got := GetBalance(id, carol); got != -33 {
		t.Fatalf("carol balance: expected -33, got %d", got)
	}
}
