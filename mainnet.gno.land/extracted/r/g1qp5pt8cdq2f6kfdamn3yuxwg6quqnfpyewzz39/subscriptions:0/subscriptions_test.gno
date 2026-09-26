package subscriptions

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	testAdmin = testutils.TestAddress("subadmin")
	prov1     = testutils.TestAddress("subprov1")
	prov2     = testutils.TestAddress("subprov2")
	alice     = testutils.TestAddress("subalice")
	bob       = testutils.TestAddress("subbob")
	mallory   = testutils.TestAddress("submallory")
)

// Established harness facts, carried from the sibling realms' suites:
// init runs with an empty origin context (the real deploy captures the
// origin caller); the banker resets between tests while realm globals
// persist, so conservation is asserted in DELTA form after re-seeding
// carried liabilities; testing.SetRealm affects only the frame that
// calls it; and testing.SkipHeights WIPES the origin/realm context, so
// every caller is re-armed after a skip.
func init() {
	admin = testAdmin
	feeRecipient = testAdmin
	self = chain.PackageAddress("gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/subscriptions")
}

type baseline struct{ held, users, fees int64 }

func begin() baseline {
	if l := Liabilities(); l > 0 {
		testing.IssueCoins(Address(), ugnot(l))
	}
	return snap()
}

func snap() baseline {
	return baseline{held: Held(), users: UsersTotal(), fees: FeesAccrued()}
}

// conserved asserts ΔH == ΔU + ΔF + extraSurplus — the realm's monetary
// invariant in delta form. There is no escrow pool in this realm.
func (b baseline) conserved(t *testing.T, extraSurplus int64) {
	t.Helper()
	dH := Held() - b.held
	dU := UsersTotal() - b.users
	dF := FeesAccrued() - b.fees
	if dH != dU+dF+extraSurplus {
		t.Fatalf("conservation violated: ΔH=%d ΔU=%d ΔF=%d ΔS=%d", dH, dU, dF, extraSurplus)
	}
	if Liabilities() != UsersTotal()+FeesAccrued() {
		t.Fatalf("Liabilities() = %d, want U+F", Liabilities())
	}
}

func coinsOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, Denom)
}

func ugnot(n int64) chain.Coins {
	return chain.NewCoins(chain.NewCoin(Denom, n))
}

// NOTE ON THE HARNESS. testing.SetRealm applies to the frame that CALLS
// it, so the caller identity must be armed in the SAME frame as the
// entrypoint invocation — the three lines are inlined at every site,
// matching the sibling suites.

// planAs publishes a plan (non-payable: envelope explicitly cleared).
func planAs(cur realm, from address, title string, price, period int64) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	testing.SetOriginCaller(from)
	testing.SetOriginSend(nil)
	return CreatePlan(cross(cur), title, "d", price, period, MaxFeeBps)
}

// subscribeAs performs a chain-faithful subscribe: envelope staged AND landed.
func subscribeAs(cur realm, from address, planID, pay int64) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	testing.SetOriginCaller(from)
	testing.SetOriginSend(ugnot(pay))
	testing.IssueCoins(Address(), ugnot(pay))
	return Subscribe(cross(cur), planID)
}

// renewAs performs a chain-faithful renewal.
func renewAs(cur realm, from address, subID, pay int64) {
	testing.SetRealm(testing.NewUserRealm(from))
	testing.SetOriginCaller(from)
	testing.SetOriginSend(ugnot(pay))
	testing.IssueCoins(Address(), ugnot(pay))
	Renew(cross(cur), subID)
}

func TestInitialConfig(t *testing.T) {
	if Admin() != testAdmin || FeeRecipient() != testAdmin {
		t.Fatal("seeded roles mismatch")
	}
	var zero address
	if PendingAdmin() != zero {
		t.Fatal("pending admin not zero")
	}
	if FeeBps() != 0 || NumPlans() != 0 || NumSubs() != 0 {
		t.Fatal("initial counters not zero")
	}
}

func TestCreatePlanValidation(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(ugnot(5))
	uassert.AbortsWithMessage(t, cur, "this function does not accept coins", func() {
		CreatePlan(cross(cur), "x", "d", 1, MinPeriodBlocks, MaxFeeBps)
	})

	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "title must be", func() {
		CreatePlan(cross(cur), "", "d", 1, MinPeriodBlocks, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "title must be", func() {
		CreatePlan(cross(cur), strings.Repeat("t", MaxTitleLen+1), "d", 1, MinPeriodBlocks, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "description too long", func() {
		CreatePlan(cross(cur), "x", strings.Repeat("d", MaxDescLen+1), 1, MinPeriodBlocks, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "price must be at least", func() {
		CreatePlan(cross(cur), "x", "d", 0, MinPeriodBlocks, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "periodBlocks must be in", func() {
		CreatePlan(cross(cur), "x", "d", 1, MinPeriodBlocks-1, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "periodBlocks must be in", func() {
		CreatePlan(cross(cur), "x", "d", 1, MaxPeriodBlocks+1, MaxFeeBps)
	})
}

func TestFeeConsentCeiling(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), 250)

	// A provider who signed for at most 100 bps is refused while the
	// fee is 250.
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "exceeds the caller's maximum", func() {
		CreatePlan(cross(cur), "capped", "d", 100, MinPeriodBlocks, 100)
	})

	// A consenting provider snapshots 250 into the plan; a later fee
	// change does not touch it.
	id := planAs(cur, prov1, "snap", 1000, MinPeriodBlocks)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), 0)
	_, _, _, _, planFee, _, _ := PlanInfo(id)
	if planFee != 250 {
		t.Fatalf("plan feeBps = %d, want the 250 snapshot", planFee)
	}

	// The subscription charges the SNAPSHOT, not the current fee.
	b := begin()
	subscribeAs(cur, alice, id, 1000)
	if got := FeesAccrued() - b.fees; got != 25 {
		t.Fatalf("fee charged = %d, want 25 (250 bps of 1000)", got)
	}
	if got := BalanceOf(prov1); got == 0 {
		t.Fatal("provider not credited")
	}
	b.conserved(t, 0)
}

func TestPlanQuota(cur realm, t *testing.T) {
	for i := 0; i < MaxPlansPerProvider; i++ {
		planAs(cur, prov2, "q", 1, MinPeriodBlocks)
	}
	testing.SetRealm(testing.NewUserRealm(prov2))
	testing.SetOriginCaller(prov2)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "per-provider plan limit reached", func() {
		CreatePlan(cross(cur), "q", "d", 1, MinPeriodBlocks, MaxFeeBps)
	})
	// Retiring one frees the slot.
	RetirePlan(cross(cur), NumPlans()-1)
	planAs(cur, prov2, "q2", 1, MinPeriodBlocks)
}

func TestRetirePlanAuthority(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "mine", 5, MinPeriodBlocks)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the provider may retire a plan", func() {
		RetirePlan(cross(cur), id)
	})
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	RetirePlan(cross(cur), id)
	uassert.AbortsWithMessage(t, cur, "plan is not active", func() {
		RetirePlan(cross(cur), id)
	})
	// No new subscriptions on a retired plan.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginCaller(alice)
	testing.SetOriginSend(ugnot(5))
	testing.IssueCoins(Address(), ugnot(5))
	uassert.AbortsWithMessage(t, cur, "plan is not active", func() {
		Subscribe(cross(cur), id)
	})
}

func TestSubscribeLifecycle(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "basic", 100, 50)
	b := begin()
	h0 := runtime.ChainHeight()
	subID := subscribeAs(cur, alice, id, 100)

	planID, subscriber, provider, price, paidThrough, periods, status := SubInfo(subID)
	if planID != id || subscriber != alice || provider != prov1 || price != 100 ||
		periods != 1 || status != SubActive {
		t.Fatal("subscription fields wrong")
	}
	if paidThrough != h0+50 {
		t.Fatalf("paidThrough = %d, want %d", paidThrough, h0+50)
	}
	if !Entitled(subID) || !EntitledFor(id, alice) {
		t.Fatal("fresh subscription not entitled")
	}
	if got, ok := ActiveSubID(id, alice); !ok || got != subID {
		t.Fatal("active index wrong")
	}
	b.conserved(t, 0)

	// Exact envelope: under- and overpayment refused.
	for _, bad := range []int64{99, 101} {
		testing.SetRealm(testing.NewUserRealm(bob))
		testing.SetOriginCaller(bob)
		testing.SetOriginSend(ugnot(bad))
		testing.IssueCoins(Address(), ugnot(bad))
		uassert.AbortsContains(t, cur, "send exactly the plan price", func() {
			Subscribe(cross(cur), id)
		})
	}

	// A second live subscription to the same plan is refused — the
	// identity-level duplicate-payment guard.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginCaller(alice)
	testing.SetOriginSend(ugnot(100))
	testing.IssueCoins(Address(), ugnot(100))
	uassert.AbortsContains(t, cur, "renew it instead", func() {
		Subscribe(cross(cur), id)
	})
}

func TestRenewalWindow(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "window", 100, 50)
	subID := subscribeAs(cur, bob, id, 100)
	_, _, _, _, pt0, _, _ := SubInfo(subID)

	from, until := RenewableFrom(subID)
	if from != pt0-50 || until != pt0+49 {
		t.Fatalf("window [%d,%d], want [%d,%d]", from, until, pt0-50, pt0+49)
	}

	// Straight after Subscribe, remaining entitlement equals exactly
	// one period (the running one), so ONE prepay renewal is inside
	// the early bound — and extension is FROM paidThrough.
	b := begin()
	renewAs(cur, bob, subID, 100)
	_, _, _, _, pt1, periods, _ := SubInfo(subID)
	if pt1 != pt0+50 || periods != 2 {
		t.Fatalf("paidThrough = %d periods = %d, want %d and 2", pt1, periods, pt0+50)
	}
	b.conserved(t, 0)

	// A SECOND renewal in the same block is the accidental duplicate,
	// and the early bound refuses it: more than one unstarted period
	// would be prepaid.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginCaller(bob)
	testing.SetOriginSend(ugnot(100))
	testing.IssueCoins(Address(), ugnot(100))
	uassert.AbortsContains(t, cur, "too early", func() {
		Renew(cross(cur), subID)
	})

	// Wrong payer: a third party cannot extend someone else's
	// subscription even inside the window.
	testing.SkipHeights(50)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(ugnot(100))
	testing.IssueCoins(Address(), ugnot(100))
	uassert.AbortsWithMessage(t, cur, "only the subscriber may renew", func() {
		Renew(cross(cur), subID)
	})

	// Wrong amount inside the window.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginCaller(bob)
	testing.SetOriginSend(ugnot(99))
	testing.IssueCoins(Address(), ugnot(99))
	uassert.AbortsContains(t, cur, "send exactly the subscription price", func() {
		Renew(cross(cur), subID)
	})
}

func TestGraceBoundary(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "grace", 100, 50)
	subID := subscribeAs(cur, alice, id, 100)
	_, _, _, _, pt, _, _ := SubInfo(subID)

	// Move to the LAST renewable height: h == paidThrough +
	// periodBlocks - 1 (the late bound is exclusive — audit Y2).
	testing.SkipHeights(pt + 49 - runtime.ChainHeight())
	if Entitled(subID) {
		t.Fatal("entitlement must have lapsed past paidThrough")
	}
	// Renewal at the boundary is accepted, extends FROM paidThrough —
	// and buys at least one block: the Y2 regression.
	renewAs(cur, alice, subID, 100)
	_, _, _, _, pt1, _, _ := SubInfo(subID)
	if pt1 != pt+50 {
		t.Fatalf("paidThrough = %d, want %d (extension from paidThrough)", pt1, pt+50)
	}
	if !Entitled(subID) {
		t.Fatal("a boundary renewal must buy at least one block of entitlement")
	}

	// At the grace end itself renewal is refused, Expire opens: the
	// two sets partition exactly.
	testing.SkipHeights(pt1 + 50 - runtime.ChainHeight())
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginCaller(alice)
	testing.SetOriginSend(ugnot(100))
	testing.IssueCoins(Address(), ugnot(100))
	uassert.AbortsContains(t, cur, "grace window over", func() {
		Renew(cross(cur), subID)
	})

	// Expire is permissionless: mallory may.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	Expire(cross(cur), subID)
	_, _, _, _, _, _, status := SubInfo(subID)
	if status != SubExpired {
		t.Fatal("not expired")
	}
	if EntitledFor(id, alice) {
		t.Fatal("expired subscription still indexed")
	}
	// Terminal: renewal refused by status.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginCaller(alice)
	testing.SetOriginSend(ugnot(100))
	testing.IssueCoins(Address(), ugnot(100))
	uassert.AbortsContains(t, cur, "subscription is expired", func() {
		Renew(cross(cur), subID)
	})
	// The slot is free: a fresh Subscribe works.
	subscribeAs(cur, alice, id, 100)
}

func TestExpireGuards(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "expguard", 100, 50)
	subID := subscribeAs(cur, bob, id, 100)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "not expirable", func() {
		Expire(cross(cur), subID)
	})
	// One block before the grace end it is still not expirable...
	_, _, _, _, pt, _, _ := SubInfo(subID)
	testing.SkipHeights(pt + 49 - runtime.ChainHeight())
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "not expirable", func() {
		Expire(cross(cur), subID)
	})
	// ...and AT the grace end it is: the sets partition exactly.
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	Expire(cross(cur), subID)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "subscription is expired", func() {
		Expire(cross(cur), subID)
	})
}

func TestSubscribeCollapsesExpiredIncumbent(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "collapse", 100, 50)
	oldID := subscribeAs(cur, alice, id, 100)
	_, _, _, _, pt, _, _ := SubInfo(oldID)
	testing.SkipHeights(pt + 50 - runtime.ChainHeight())

	// No Expire call happened; Subscribe collapses the incumbent
	// itself, at the first expirable height.
	newID := subscribeAs(cur, alice, id, 100)
	if newID == oldID {
		t.Fatal("expected a fresh subscription id")
	}
	_, _, _, _, _, _, oldStatus := SubInfo(oldID)
	if oldStatus != SubExpired {
		t.Fatalf("incumbent status = %q, want expired", oldStatus)
	}
	if got, ok := ActiveSubID(id, alice); !ok || got != newID {
		t.Fatal("index does not point at the fresh subscription")
	}
}

func TestCancel(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "cancel", 100, 50)
	subID := subscribeAs(cur, bob, id, 100)

	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the subscriber may cancel", func() {
		Cancel(cross(cur), subID)
	})

	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginCaller(bob)
	testing.SetOriginSend(nil)
	Cancel(cross(cur), subID)
	_, _, _, _, _, _, status := SubInfo(subID)
	if status != SubCancelled {
		t.Fatal("not cancelled")
	}
	// Paid entitlement survives cancellation until paidThrough — on
	// both surfaces (audit Y1)...
	if !Entitled(subID) || !EntitledFor(id, bob) {
		t.Fatal("cancelled subscription lost its paid entitlement")
	}
	// ...but the ACTIVE slot is gone and renewal is refused forever.
	if _, ok := ActiveSubID(id, bob); ok {
		t.Fatal("cancelled subscription still holds the active slot")
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginCaller(bob)
	testing.SetOriginSend(ugnot(100))
	testing.IssueCoins(Address(), ugnot(100))
	uassert.AbortsContains(t, cur, "subscription is cancelled", func() {
		Renew(cross(cur), subID)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginCaller(bob)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "subscription is cancelled", func() {
		Cancel(cross(cur), subID)
	})
	// The slot freed: bob may start a fresh subscription at once.
	subscribeAs(cur, bob, id, 100)
}

func TestRenewRefusedOnRetiredPlan(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "retire-mid", 100, 50)
	subID := subscribeAs(cur, alice, id, 100)
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	RetirePlan(cross(cur), id)
	// Entitlement continues...
	if !Entitled(subID) {
		t.Fatal("entitlement must survive plan retirement")
	}
	// ...but renewal is refused even inside the window.
	_, _, _, _, pt, _, _ := SubInfo(subID)
	testing.SkipHeights(pt - runtime.ChainHeight())
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginCaller(alice)
	testing.SetOriginSend(ugnot(100))
	testing.IssueCoins(Address(), ugnot(100))
	uassert.AbortsContains(t, cur, "plan is retired", func() {
		Renew(cross(cur), subID)
	})
}

func TestSubscriberQuota(cur realm, t *testing.T) {
	// Fill carol's quota with one-plan-each subscriptions, then refuse.
	// A dedicated provider: prov2's plan quota is already saturated by
	// TestPlanQuota, and realm globals persist across tests.
	carol := testutils.TestAddress("subcarol")
	provQ := testutils.TestAddress("subprovq")
	var lastPlan int64
	for i := 0; i < MaxSubsPerSubscriber; i++ {
		lastPlan = planAs(cur, provQ, "quota", 1, MinPeriodBlocks)
		subscribeAs(cur, carol, lastPlan, 1)
		// Free the provider quota slot for the next plan.
		testing.SetRealm(testing.NewUserRealm(provQ))
		testing.SetOriginCaller(provQ)
		testing.SetOriginSend(nil)
		RetirePlan(cross(cur), lastPlan)
	}
	extra := planAs(cur, provQ, "quota-x", 1, MinPeriodBlocks)
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginCaller(carol)
	testing.SetOriginSend(ugnot(1))
	testing.IssueCoins(Address(), ugnot(1))
	uassert.AbortsWithMessage(t, cur, "per-subscriber subscription limit reached", func() {
		Subscribe(cross(cur), extra)
	})
	// Cancelling one frees a slot.
	sid, ok := ActiveSubID(lastPlan, carol)
	if !ok {
		t.Fatal("expected an active sub to free")
	}
	testing.SetRealm(testing.NewUserRealm(carol))
	testing.SetOriginCaller(carol)
	testing.SetOriginSend(nil)
	Cancel(cross(cur), sid)
	subscribeAs(cur, carol, extra, 1)
	testing.SetRealm(testing.NewUserRealm(provQ))
	testing.SetOriginCaller(provQ)
	testing.SetOriginSend(nil)
	RetirePlan(cross(cur), extra)
}

func TestClaimsAndFees(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), 500) // 5% into the next plan
	id := planAs(cur, prov1, "money", 1000, 50)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), 0)

	b := begin()
	subscribeAs(cur, alice, id, 1000)
	if FeesAccrued()-b.fees != 50 {
		t.Fatalf("fee = %d, want 50", FeesAccrued()-b.fees)
	}
	credited := BalanceOf(prov1)

	// Mallory has no balance: claims fail.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "insufficient balance", func() { Claim(cross(cur), 1) })
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "nothing to claim", func() { ClaimAll(cross(cur)) })

	// Provider claims all; coins actually move.
	before := coinsOf(prov1)
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	ClaimAll(cross(cur))
	if coinsOf(prov1)-before != credited {
		t.Fatalf("provider received %d, want %d", coinsOf(prov1)-before, credited)
	}
	if BalanceOf(prov1) != 0 {
		t.Fatal("balance not drained")
	}

	// Fees: only the recipient, and only the pot.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "fee recipient only", func() { WithdrawFees(cross(cur)) })
	potBefore := coinsOf(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	WithdrawFees(cross(cur))
	if coinsOf(testAdmin)-potBefore == 0 {
		t.Fatal("fee pot did not move")
	}
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "no fees accrued", func() { WithdrawFees(cross(cur)) })
	b.conserved(t, 0)
}

func TestSweepReserve(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "sweep", 500, 50)
	begin()
	subscribeAs(cur, bob, id, 500)

	// Nothing above the reserve: sweep refuses.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "no surplus to sweep", func() {
		SweepDenom(cross(cur), Denom)
	})
	// Out-of-band surplus lands; only the surplus is sweepable.
	testing.IssueCoins(Address(), ugnot(77))
	liabBefore := Liabilities()
	got := coinsOf(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SweepDenom(cross(cur), Denom)
	if coinsOf(testAdmin)-got != 77 {
		t.Fatalf("swept %d, want 77", coinsOf(testAdmin)-got)
	}
	if Liabilities() != liabBefore {
		t.Fatal("sweep touched the reserve")
	}
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "fee recipient only", func() {
		SweepDenom(cross(cur), Denom)
	})
}

func TestAdminHandover(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		TransferAdmin(cross(cur), mallory)
	})
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	TransferAdmin(cross(cur), prov2)
	// Wrong acceptor refused; authority has not moved yet.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the staged successor may accept", func() {
		AcceptAdmin(cross(cur))
	})
	if Admin() != testAdmin {
		t.Fatal("authority moved before acceptance")
	}
	testing.SetRealm(testing.NewUserRealm(prov2))
	testing.SetOriginCaller(prov2)
	testing.SetOriginSend(nil)
	AcceptAdmin(cross(cur))
	if Admin() != prov2 {
		t.Fatal("authority did not move")
	}
	// The former admin is locked out.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		SetFeeBps(cross(cur), 1)
	})
	// Hand it back for the remaining tests.
	testing.SetRealm(testing.NewUserRealm(prov2))
	testing.SetOriginCaller(prov2)
	testing.SetOriginSend(nil)
	TransferAdmin(cross(cur), testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	AcceptAdmin(cross(cur))
}

func TestFeeBounds(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "fee must be in", func() {
		SetFeeBps(cross(cur), MaxFeeBps+1)
	})
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "fee must be in", func() {
		SetFeeBps(cross(cur), -1)
	})
	var zero address
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "fee recipient must not be the zero address", func() {
		SetFeeRecipient(cross(cur), zero)
	})
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "successor must not be the zero address", func() {
		TransferAdmin(cross(cur), zero)
	})
}

func TestStraySendRejected(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "stray", 100, 50)
	subID := subscribeAs(cur, alice, id, 100)
	arm := func(from address) {
		testing.SetRealm(testing.NewUserRealm(from))
		testing.SetOriginCaller(from)
		testing.SetOriginSend(ugnot(3))
	}
	arm(prov1)
	uassert.AbortsWithMessage(t, cur, "this function does not accept coins", func() {
		RetirePlan(cross(cur), id)
	})
	arm(alice)
	uassert.AbortsWithMessage(t, cur, "this function does not accept coins", func() {
		Cancel(cross(cur), subID)
	})
	arm(mallory)
	uassert.AbortsWithMessage(t, cur, "this function does not accept coins", func() {
		Expire(cross(cur), subID)
	})
	arm(prov1)
	uassert.AbortsWithMessage(t, cur, "this function does not accept coins", func() {
		ClaimAll(cross(cur))
	})
	arm(testAdmin)
	uassert.AbortsWithMessage(t, cur, "this function does not accept coins", func() {
		WithdrawFees(cross(cur))
	})
	arm(testAdmin)
	uassert.AbortsWithMessage(t, cur, "this function does not accept coins", func() {
		SetFeeBps(cross(cur), 0)
	})
}

func TestRenderSanitizes(cur realm, t *testing.T) {
	planAs(cur, prov1, "[evil](https://x) <script>alert(1)</script>", 1, MinPeriodBlocks)
	out := Render("")
	if strings.Contains(out, "<script>") {
		t.Fatal("unsanitized title reached Render")
	}
	if !strings.Contains(out, "plans:") {
		t.Fatal("render missing counters")
	}
	if Render("nope") == renderHome() {
		t.Fatal("unknown path fell through to home")
	}
}

func TestUnknownIDs(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("expected panic")
		}
	}()
	PlanInfo(99999)
}

// Y1 regression: EntitledFor follows the most recent subscription and
// honors paid entitlement across cancellation.
func TestEntitledForSurvivesCancel(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "y1", 100, 50)
	subID := subscribeAs(cur, alice, id, 100)
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginCaller(alice)
	testing.SetOriginSend(nil)
	Cancel(cross(cur), subID)
	if !EntitledFor(id, alice) {
		t.Fatal("cancelled-but-paid subscriber lost EntitledFor")
	}
	// A fresh Subscribe repoints the surface at the new subscription.
	// Skip a few blocks first so ptNew > ptOld: at a height in
	// [ptOld, ptNew) a STALE pointer would answer false while the
	// repointed one answers true — the distinguishing assertion.
	_, _, _, _, ptOld, _, _ := SubInfo(subID)
	testing.SkipHeights(5)
	newID := subscribeAs(cur, alice, id, 100)
	_, _, _, _, ptNew, _, _ := SubInfo(newID)
	if ptNew <= ptOld {
		t.Fatal("fixture broken: ptNew must exceed ptOld")
	}
	if !EntitledFor(id, alice) || !Entitled(newID) || !Entitled(subID) {
		t.Fatal("both paid entitlements should be live right after re-subscribe")
	}
	testing.SkipHeights(ptOld - runtime.ChainHeight())
	if Entitled(subID) {
		t.Fatal("old span should have run out")
	}
	if !EntitledFor(id, alice) {
		t.Fatal("EntitledFor answered the stale id, not the repointed one")
	}
	// After the new paid span runs out too, EntitledFor goes false.
	testing.SkipHeights(ptNew - runtime.ChainHeight())
	if EntitledFor(id, alice) {
		t.Fatal("EntitledFor true past paidThrough")
	}
}

// Y2 companion: a lapsed-in-grace incumbent blocks Subscribe with a
// message that states both options.
func TestSubscribeMessageInGrace(cur realm, t *testing.T) {
	id := planAs(cur, prov1, "y2msg", 100, 50)
	subID := subscribeAs(cur, bob, id, 100)
	_, _, _, _, pt, _, _ := SubInfo(subID)
	testing.SkipHeights(pt + 10 - runtime.ChainHeight())
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginCaller(bob)
	testing.SetOriginSend(ugnot(100))
	testing.IssueCoins(Address(), ugnot(100))
	uassert.AbortsContains(t, cur, "lapsed but renewable", func() {
		Subscribe(cross(cur), id)
	})
	// Cancel + Subscribe is the documented fresh-start path.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginCaller(bob)
	testing.SetOriginSend(nil)
	Cancel(cross(cur), subID)
	subscribeAs(cur, bob, id, 100)
}
