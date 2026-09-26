package revshare

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"

	subs "gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/subscriptions"
)

var (
	testAdmin = testutils.TestAddress("rsadmin")
	alice     = testutils.TestAddress("rsalice")
	bob       = testutils.TestAddress("rsbob")
	subber    = testutils.TestAddress("rssubber")
	subber2   = testutils.TestAddress("rssubber2")
	mallory   = testutils.TestAddress("rsmallory")
)

// Harness facts, carried from the sibling suites: init runs with an
// empty origin (real deploys capture the signer); realm globals persist
// across tests while the banker resets; SetRealm binds to the CALLING
// frame only, so arming is inlined at every site; SkipHeights wipes the
// origin context. NEW for a two-realm money suite: the banker reset
// hits BOTH realms, so held-balance sync must restore revshare's
// backing AND the downstream subscriptions realm's backing, or the
// first cross-boundary banker send machine-panics the run.
func init() {
	admin = testAdmin
	sweeper = testAdmin
	self = chain.PackageAddress("gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/revshare")
}

func ugnot(n int64) chain.Coins { return chain.NewCoins(chain.NewCoin(Denom, n)) }

func coinsOf(a address) int64 { return banker.NewReadonlyBanker().GetCoin(a, Denom) }

// conserved asserts the local conservation equation at rest:
// everything this realm holds is members' earned-but-unclaimed value.
// (Out-of-band surplus tests manage their own expectations.)
func conserved(t *testing.T) {
	t.Helper()
	if Held() != UsersTotal() {
		t.Fatalf("conservation violated: Held=%d users=%d", Held(), UsersTotal())
	}
}

// syncHeld restores BOTH realms' banker backing to match their
// persistent ledgers after the harness banker reset.
func syncHeld() {
	if want, have := UsersTotal(), coinsOf(Address()); want > have {
		testing.IssueCoins(Address(), ugnot(want-have))
	}
	if want, have := subs.Liabilities(), coinsOf(subs.Address()); want > have {
		testing.IssueCoins(subs.Address(), ugnot(want-have))
	}
}

// SetRealm binds to the CALLING frame only, so arming is inlined at
// every call site — a helper that arms and returns is silently
// ineffective (the sibling suites' documented trap).

// subscribe drives the REAL subscriptions realm: who pays exactly
// price into planID. Nothing is mocked.
func subscribe(cur realm, t *testing.T, who address, planID, price int64) int64 {
	t.Helper()
	testing.SetRealm(testing.NewUserRealm(who))
	testing.SetOriginCaller(who)
	testing.SetOriginSend(ugnot(price))
	testing.IssueCoins(subs.Address(), ugnot(price))
	return subs.Subscribe(cross(cur), planID)
}

func TestInitialState(t *testing.T) {
	if Admin() != testAdmin || MemberCount() != 0 || TotalWeight() != 0 ||
		Pulled() != 0 || NumPlans() != 0 {
		t.Fatal("unexpected initial state")
	}
	conserved(t)
}

// The no-members refusal must fire BEFORE any downstream call.
func TestPullNoMembers(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "no members configured to receive revenue", func() {
		Pull(cross(cur))
	})
}

func TestMembership(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		AddMember(cross(cur), alice, 3)
	})

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	var zero address
	uassert.AbortsContains(t, cur, "zero address", func() {
		AddMember(cross(cur), zero, 1)
	})
	uassert.AbortsContains(t, cur, "weight must be in", func() {
		AddMember(cross(cur), alice, 0)
	})
	uassert.AbortsContains(t, cur, "weight must be in", func() {
		AddMember(cross(cur), alice, MaxWeight+1)
	})

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	AddMember(cross(cur), alice, 3)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	AddMember(cross(cur), bob, 1)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "already a member", func() {
		AddMember(cross(cur), alice, 5)
	})
	uassert.AbortsWithMessage(t, cur, "not a member", func() {
		SetWeight(cross(cur), mallory, 2)
	})
	uassert.AbortsContains(t, cur, "weight must be in", func() {
		SetWeight(cross(cur), alice, 0)
	})

	if MemberCount() != 2 || TotalWeight() != 4 ||
		MemberWeight(alice) != 3 || MemberWeight(bob) != 1 {
		t.Fatal("membership state wrong")
	}
}

// The provider flow across all three value boundaries, against the
// REAL subscriptions realm.
func TestProviderFlowAndPull(cur realm, t *testing.T) {
	syncHeld()

	// Plan creation is admin-gated HERE (quota griefing) before the
	// downstream call.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		CreatePlan(cross(cur), "team", "d", 1000, 10, 1000)
	})

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	planID := CreatePlan(cross(cur), "team", "d", 1000, 10, 1000)
	if NumPlans() != 1 || PlanID(0) != planID {
		t.Fatal("plan bookkeeping wrong")
	}

	// Downstream truth: the PROVIDER of the plan is this realm.
	provider, _, price, _, _, status, _ := subs.PlanInfo(planID)
	if provider != Address() || price != 1000 || status != "active" {
		t.Fatalf("downstream plan wrong: provider=%v price=%d status=%q",
			provider, price, status)
	}

	// Boundary B1: subscriber pays the subscriptions realm directly.
	subID := subscribe(cur, t, subber, planID, 1000)
	if Receivable() != 1000 {
		t.Fatalf("receivable=%d, want 1000", Receivable())
	}
	if Held() != 0 {
		t.Fatal("nothing should be held here before Pull")
	}
	_ = subID

	// Boundary B2: anyone may crank the pull (permissionless).
	heldBefore := Held()
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	got := Pull(cross(cur))
	if got != 1000 || Held()-heldBefore != 1000 || Receivable() != 0 {
		t.Fatalf("pull moved wrong value: got=%d held=%d receivable=%d",
			got, Held(), Receivable())
	}
	// 3:1 split of 1000 -> 750 / 250, no dust.
	if BalanceOf(alice) != 750 || BalanceOf(bob) != 250 || BalanceOf(mallory) != 0 {
		t.Fatalf("split wrong: alice=%d bob=%d mallory=%d",
			BalanceOf(alice), BalanceOf(bob), BalanceOf(mallory))
	}
	if Pulled() != 1000 || UsersTotal() != 1000 {
		t.Fatal("lifetime accounting wrong")
	}
	conserved(t)
}

// Replay: the downstream realm holds the replay guard — an empty
// receivable aborts there and no local state changes.
func TestPullReplay(cur realm, t *testing.T) {
	syncHeld()
	usersBefore, pulledBefore := UsersTotal(), Pulled()
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "nothing to claim", func() {
		Pull(cross(cur))
	})
	if UsersTotal() != usersBefore || Pulled() != pulledBefore {
		t.Fatal("aborted pull mutated state")
	}
	conserved(t)
}

// Rounding: dust goes to the highest-weight member, deterministically,
// and the sum always equals the pulled amount exactly.
func TestRoundingDust(cur realm, t *testing.T) {
	syncHeld()
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	planID := CreatePlan(cross(cur), "odd", "d", 1001, 10, 1000)
	subscribe(cur, t, subber2, planID, 1001)

	a0, b0 := BalanceOf(alice), BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	Pull(cross(cur))
	// 1001 at 3:1 -> alice floor 750 + dust 1 = 751, bob 250.
	if BalanceOf(alice)-a0 != 751 || BalanceOf(bob)-b0 != 250 {
		t.Fatalf("dust policy wrong: alice+%d bob+%d",
			BalanceOf(alice)-a0, BalanceOf(bob)-b0)
	}
	conserved(t)
}

// Minimum values: a 1ugnot pull where every floor share is zero still
// conserves — the whole amount is dust to the highest weight.
func TestMinimumPull(cur realm, t *testing.T) {
	syncHeld()
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	planID := CreatePlan(cross(cur), "min", "d", 1, 10, 1000)
	subscribe(cur, t, subber, planID, 1)

	a0, b0 := BalanceOf(alice), BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	got := Pull(cross(cur))
	if got != 1 || BalanceOf(alice)-a0 != 1 || BalanceOf(bob)-b0 != 0 {
		t.Fatal("minimum pull mishandled")
	}
	conserved(t)
}

// Weight changes shape FUTURE pulls only; earned balances never move.
func TestWeightChangeFutureOnly(cur realm, t *testing.T) {
	syncHeld()
	a0, b0 := BalanceOf(alice), BalanceOf(bob)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetWeight(cross(cur), bob, 3)
	if BalanceOf(alice) != a0 || BalanceOf(bob) != b0 {
		t.Fatal("weight change touched earned balances")
	}
	if TotalWeight() != 6 {
		t.Fatalf("totalWeight=%d, want 6", TotalWeight())
	}

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	planID := CreatePlan(cross(cur), "even", "d", 600, 10, 1000)
	subscribe(cur, t, subber2, planID, 600)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	Pull(cross(cur))
	// 600 at 3:3 -> 300 each.
	if BalanceOf(alice)-a0 != 300 || BalanceOf(bob)-b0 != 300 {
		t.Fatal("new weights not applied to new revenue")
	}
	conserved(t)
}

// Boundary B3: members pull their earnings out; strangers get nothing.
func TestClaims(cur realm, t *testing.T) {
	syncHeld()
	earned := BalanceOf(alice)
	if earned == 0 {
		t.Fatal("fixture: alice should have earnings")
	}
	before := coinsOf(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginCaller(alice)
	testing.SetOriginSend(nil)
	ClaimAll(cross(cur))
	if coinsOf(alice)-before != earned || BalanceOf(alice) != 0 {
		t.Fatal("claim did not move the earned balance")
	}

	bobBefore, bobCoins := BalanceOf(bob), coinsOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginCaller(bob)
	testing.SetOriginSend(nil)
	Claim(cross(cur), 100)
	if BalanceOf(bob) != bobBefore-100 || coinsOf(bob)-bobCoins != 100 {
		t.Fatal("partial claim wrong")
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginCaller(bob)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "insufficient balance", func() {
		Claim(cross(cur), BalanceOf(bob)+1)
	})

	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "nothing to claim", func() {
		ClaimAll(cross(cur))
	})
	conserved(t)
}

// Removal never touches earned value: the ex-member keeps claiming.
func TestRemoveMemberKeepsBalance(cur realm, t *testing.T) {
	syncHeld()
	bobBal := BalanceOf(bob)
	if bobBal == 0 {
		t.Fatal("fixture: bob should still have a balance")
	}
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	RemoveMember(cross(cur), bob)
	if MemberCount() != 1 || TotalWeight() != 3 || BalanceOf(bob) != bobBal {
		t.Fatal("removal corrupted state")
	}

	// Future revenue goes entirely to the remaining member.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	planID := CreatePlan(cross(cur), "solo", "d", 500, 10, 1000)
	subscribe(cur, t, subber, planID, 500)
	a0 := BalanceOf(alice)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	Pull(cross(cur))
	if BalanceOf(alice)-a0 != 500 || BalanceOf(bob) != bobBal {
		t.Fatal("post-removal distribution wrong")
	}

	// The ex-member's balance remains claimable.
	before := coinsOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginCaller(bob)
	testing.SetOriginSend(nil)
	ClaimAll(cross(cur))
	if coinsOf(bob)-before != bobBal {
		t.Fatal("ex-member could not claim")
	}
	conserved(t)
}

// Plan retirement crosses the boundary admin-gated here, provider-only
// downstream.
func TestRetirePlan(cur realm, t *testing.T) {
	syncHeld()
	planID := PlanID(0)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		RetirePlan(cross(cur), planID)
	})
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	RetirePlan(cross(cur), planID)
	_, _, _, _, _, status, _ := subs.PlanInfo(planID)
	if status != "retired" {
		t.Fatalf("downstream not retired: %q", status)
	}
	// Downstream refuses new subscriptions to a retired plan.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(ugnot(1000))
	testing.IssueCoins(subs.Address(), ugnot(1000))
	uassert.AbortsContains(t, cur, "plan is not active", func() {
		subs.Subscribe(cross(cur), planID)
	})
}

// Every entrypoint refuses coin-carrying transactions.
func TestStraySend(cur realm, t *testing.T) {
	for _, f := range []func(){
		func() { Pull(cross(cur)) },
		func() { ClaimAll(cross(cur)) },
		func() { AddMember(cross(cur), mallory, 1) },
		func() { CreatePlan(cross(cur), "x", "d", 1000, 10, 1000) },
		func() { SweepDenom(cross(cur), Denom) },
	} {
		testing.SetRealm(testing.NewUserRealm(testAdmin))
		testing.SetOriginCaller(testAdmin)
		testing.SetOriginSend(ugnot(5))
		uassert.AbortsWithMessage(t, cur, "this function does not accept coins", f)
	}
}

// Out-of-band value: the reserve protects member balances; foreign
// denominations sweep in full.
func TestSweepReserve(cur realm, t *testing.T) {
	syncHeld()
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "no surplus to sweep", func() {
		SweepDenom(cross(cur), Denom)
	})

	testing.IssueCoins(Address(), ugnot(77))
	reserveBefore := UsersTotal()
	got := coinsOf(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SweepDenom(cross(cur), Denom)
	if coinsOf(testAdmin)-got != 77 || UsersTotal() != reserveBefore {
		t.Fatal("sweep wrong or touched the reserve")
	}

	testing.IssueCoins(Address(), chain.NewCoins(chain.NewCoin("foo", 9)))
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SweepDenom(cross(cur), "foo")
	if banker.NewReadonlyBanker().GetCoin(testAdmin, "foo") != 9 {
		t.Fatal("foreign denom not swept in full")
	}

	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "sweeper only", func() {
		SweepDenom(cross(cur), Denom)
	})
	conserved(t)
}

func TestAdminHandover(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	TransferAdmin(cross(cur), alice)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the staged successor may accept", func() {
		AcceptAdmin(cross(cur))
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginCaller(alice)
	testing.SetOriginSend(nil)
	AcceptAdmin(cross(cur))
	if Admin() != alice {
		t.Fatal("authority did not move")
	}
	// Former admin locked out of members, plans and sweep.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		AddMember(cross(cur), mallory, 1)
	})
	uassert.AbortsWithMessage(t, cur, "sweeper only", func() {
		SweepDenom(cross(cur), Denom)
	})
	// Hand back.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginCaller(alice)
	testing.SetOriginSend(nil)
	TransferAdmin(cross(cur), testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	AcceptAdmin(cross(cur))
}

func TestMemberTableBounds(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	for i := MemberCount(); i < int64(MaxMembers); i++ {
		testing.SetRealm(testing.NewUserRealm(testAdmin))
		testing.SetOriginCaller(testAdmin)
		testing.SetOriginSend(nil)
		AddMember(cross(cur), testutils.TestAddress("rsfill"+string(rune('a'+i))), 1)
	}
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "member table is full", func() {
		AddMember(cross(cur), testutils.TestAddress("rsoverflow"), 1)
	})
}

func TestRender(t *testing.T) {
	out := Render("")
	if !strings.Contains(out, "receivable") || !strings.Contains(out, "| member |") {
		t.Fatal("render missing sections")
	}
	if Render("x") == Render("") {
		t.Fatal("unknown path fell through")
	}
}
