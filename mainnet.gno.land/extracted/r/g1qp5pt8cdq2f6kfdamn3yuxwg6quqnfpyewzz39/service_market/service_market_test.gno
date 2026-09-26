package service_market

import (
	"chain"
	"chain/banker"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

var (
	testAdmin = testutils.TestAddress("smadmin")
	prov1     = testutils.TestAddress("smprov1")
	prov2     = testutils.TestAddress("smprov2")
	cust1     = testutils.TestAddress("smcust1")
	cust2     = testutils.TestAddress("smcust2")
	mallory   = testutils.TestAddress("smmallory")
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
	self = chain.PackageAddress("gno.land/r/g1qp5pt8cdq2f6kfdamn3yuxwg6quqnfpyewzz39/service_market")
}

type baseline struct{ held, escrow, users, fees int64 }

func begin() baseline {
	if l := Liabilities(); l > 0 {
		testing.IssueCoins(Address(), ugnot(l))
	}
	return snap()
}

func snap() baseline {
	return baseline{held: Held(), escrow: EscrowTotal(), users: UsersTotal(), fees: FeesAccrued()}
}

// conserved asserts ΔH == ΔE + ΔU + ΔF + extraSurplus, the realm's
// stated monetary invariant in delta form.
func (b baseline) conserved(t *testing.T, extraSurplus int64) {
	t.Helper()
	dH := Held() - b.held
	dE := EscrowTotal() - b.escrow
	dU := UsersTotal() - b.users
	dF := FeesAccrued() - b.fees
	if dH != dE+dU+dF+extraSurplus {
		t.Fatalf("conservation violated: ΔH=%d ΔE=%d ΔU=%d ΔF=%d ΔS=%d", dH, dE, dU, dF, extraSurplus)
	}
	if Liabilities() != EscrowTotal()+UsersTotal()+FeesAccrued() {
		t.Fatalf("Liabilities() = %d, want E+U+F", Liabilities())
	}
}

// appInvariant re-derives the escrow pool from the orders themselves.
// EscrowTotal is a running counter; this proves it still equals Σ amount
// over non-terminal orders, which is the claim SweepDenom's reserve
// rests on.
func appInvariant(t *testing.T) {
	t.Helper()
	var sum int64
	for id := int64(0); id < NumOrders(); id++ {
		_, _, _, amount, _, status := OrderInfo(id)
		switch status {
		case OrderPurchased, OrderDelivered:
			sum += amount
		case OrderReleased, OrderRefunded:
		default:
			t.Fatalf("order %d has unknown status %q", id, status)
		}
	}
	if sum != EscrowTotal() {
		t.Fatalf("EscrowTotal() = %d, but Σ open orders = %d", EscrowTotal(), sum)
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
// entrypoint invocation. A nested `as(from)` helper is silently
// ineffective: the realm reverts when that helper returns, and the call
// lands as the default test caller instead of `from` — which is a test
// that quietly stops testing what it names. Hence the three lines
// inline at every site, matching the sibling suites.

// registerAs publishes a service (non-payable: envelope explicitly cleared).
func registerAs(cur realm, from address, title, desc string, price, delivery int64) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	testing.SetOriginCaller(from)
	testing.SetOriginSend(nil)
	return RegisterService(cross(cur), title, desc, price, delivery, MaxFeeBps)
}

// purchaseAs performs a chain-faithful purchase: envelope staged AND landed.
func purchaseAs(cur realm, from address, serviceID, pay int64) int64 {
	testing.SetRealm(testing.NewUserRealm(from))
	testing.SetOriginCaller(from)
	testing.SetOriginSend(ugnot(pay))
	testing.IssueCoins(Address(), ugnot(pay))
	return PurchaseService(cross(cur), serviceID)
}

func TestInitialConfig(t *testing.T) {
	if Admin() != testAdmin || FeeRecipient() != testAdmin {
		t.Fatal("seeded roles mismatch")
	}
	var zero address
	if PendingAdmin() != zero {
		t.Fatal("pending admin not zero")
	}
	if FeeBps() != 0 || NumServices() != 0 || NumOrders() != 0 {
		t.Fatal("initial counters not zero")
	}
	if Held() != 0 || Liabilities() != 0 || EscrowTotal() != 0 {
		t.Fatal("initial accounting not zero")
	}
	if Address() == zero {
		t.Fatal("realm address is zero")
	}
}

func TestRegisterService(cur realm, t *testing.T) {
	b := begin()
	id := registerAs(cur, prov1, "logo design", "two concepts and revisions", 500000, 20000)

	provider, title, price, delivery, snapBps, status, orderCount := ServiceInfo(id)
	if provider != prov1 || title != "logo design" || price != 500000 ||
		delivery != 20000 || snapBps != 0 || status != ServiceActive || orderCount != 0 {
		t.Fatalf("fields wrong: %v %q %d %d %d %s %d",
			provider, title, price, delivery, snapBps, status, orderCount)
	}
	if ServiceDescription(id) != "two concepts and revisions" {
		t.Fatal("description mismatch")
	}
	if ServicesOf(prov1) != 1 {
		t.Fatalf("ServicesOf = %d, want 1", ServicesOf(prov1))
	}
	p, fee, toProvider := Quote(id)
	if p != 500000 || fee != 0 || toProvider != 500000 {
		t.Fatalf("Quote = %d/%d/%d", p, fee, toProvider)
	}
	appInvariant(t)
	b.conserved(t, 0)
}

func TestRegisterRejects(cur realm, t *testing.T) {
	b := begin()

	// Non-payable: an attached envelope is refused, not stranded.
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(ugnot(100))
	uassert.AbortsWithMessage(t, cur, "this function does not accept coins", func() {
		RegisterService(cross(cur), "x", "y", 1, MinDeliveryBlocks, MaxFeeBps)
	})
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)

	uassert.AbortsContains(t, cur, "title must be", func() {
		RegisterService(cross(cur), "", "d", 1, MinDeliveryBlocks, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "title may only contain", func() {
		RegisterService(cross(cur), "bad*title", "d", 1, MinDeliveryBlocks, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "description must be", func() {
		RegisterService(cross(cur), "ok", strings.Repeat("x", MaxDescLen+1), 1, MinDeliveryBlocks, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "price must be at least", func() {
		RegisterService(cross(cur), "ok", "d", 0, MinDeliveryBlocks, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "deliveryBlocks must be", func() {
		RegisterService(cross(cur), "ok", "d", 1, MinDeliveryBlocks-1, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "deliveryBlocks must be", func() {
		RegisterService(cross(cur), "ok", "d", 1, MaxDeliveryBlocks+1, MaxFeeBps)
	})
	uassert.AbortsContains(t, cur, "maxFeeBps must be", func() {
		RegisterService(cross(cur), "ok", "d", 1, MinDeliveryBlocks, MaxFeeBps+1)
	})
	appInvariant(t)
	b.conserved(t, 0)
}

// The provider's published terms cannot be devalued by an admin fee
// change between registration and purchase: registration itself refuses
// a fee above the ceiling the provider signed for. This is the grants Y1
// pattern, applied at the offer rather than the grant.
func TestFeeCeilingAndSnapshot(cur realm, t *testing.T) {
	b := begin()

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), 500)

	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "exceeds your ceiling", func() {
		RegisterService(cross(cur), "cheap only", "d", 1000, MinDeliveryBlocks, 100)
	})

	// Registered at 500 bps.
	id := registerAs(cur, prov1, "copywriting", "800 words", 1000000, 20000)
	_, _, _, _, snapBps, _, _ := ServiceInfo(id)
	if snapBps != 500 {
		t.Fatalf("snapshot bps = %d, want 500", snapBps)
	}

	// Admin raises the fee afterwards; the existing service keeps 500.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), MaxFeeBps)
	_, _, _, _, snapBps, _, _ = ServiceInfo(id)
	if snapBps != 500 {
		t.Fatalf("snapshot bps changed to %d", snapBps)
	}

	// And an order placed now carries the SERVICE's 500, not the live cap.
	oid := purchaseAs(cur, cust1, id, 1000000)
	_, _, _, _, orderBps, _ := OrderInfo(oid)
	if orderBps != 500 {
		t.Fatalf("order bps = %d, want 500", orderBps)
	}

	// Clean up: release so later tests start from a settled pool.
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), oid, "ipfs://copy")
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)
	AcceptDelivery(cross(cur), oid)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), 0)
	appInvariant(t)
	b.conserved(t, 0)
}

func TestPurchaseEscrows(cur realm, t *testing.T) {
	b := begin()
	p0 := BalanceOf(prov1)
	sid := registerAs(cur, prov1, "translation", "en to fr", 300000, 20000)

	oid := purchaseAs(cur, cust1, sid, 300000)
	serviceID, customer, provider, amount, _, status := OrderInfo(oid)
	if serviceID != sid || customer != cust1 || provider != prov1 ||
		amount != 300000 || status != OrderPurchased {
		t.Fatalf("order wrong: %d %v %v %d %s", serviceID, customer, provider, amount, status)
	}
	// The money is in escrow, NOT yet in anyone's claimable balance.
	if EscrowTotal()-b.escrow != 300000 {
		t.Fatalf("ΔE = %d, want 300000", EscrowTotal()-b.escrow)
	}
	if BalanceOf(prov1) != p0 {
		t.Fatalf("provider credited before resolution: %d -> %d", p0, BalanceOf(prov1))
	}
	deliveryDeadline, acceptanceDeadline := OrderDeadlines(oid)
	if deliveryDeadline != Height()+20000 {
		t.Fatalf("delivery deadline = %d", deliveryDeadline)
	}
	if acceptanceDeadline != 0 {
		t.Fatalf("acceptance deadline set before delivery: %d", acceptanceDeadline)
	}
	_, _, _, _, _, _, orderCount := ServiceInfo(sid)
	if orderCount != 1 {
		t.Fatalf("service order count = %d", orderCount)
	}
	appInvariant(t)
	b.conserved(t, 0)
}

func TestPurchaseRejects(cur realm, t *testing.T) {
	b := begin()
	sid := registerAs(cur, prov1, "editing", "line edit", 250000, 20000)

	// Wrong amount, in both directions.
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(ugnot(249999))
	testing.IssueCoins(Address(), ugnot(249999))
	uassert.AbortsContains(t, cur, "send exactly the listed price", func() {
		PurchaseService(cross(cur), sid)
	})
	testing.SetOriginSend(ugnot(250001))
	testing.IssueCoins(Address(), ugnot(250001))
	uassert.AbortsContains(t, cur, "send exactly the listed price", func() {
		PurchaseService(cross(cur), sid)
	})

	// Self-purchase.
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(ugnot(250000))
	testing.IssueCoins(Address(), ugnot(250000))
	uassert.AbortsWithMessage(t, cur, "the provider cannot purchase their own service", func() {
		PurchaseService(cross(cur), sid)
	})

	// Unknown service.
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(ugnot(250000))
	testing.IssueCoins(Address(), ugnot(250000))
	uassert.AbortsWithMessage(t, cur, "unknown service id", func() {
		PurchaseService(cross(cur), 9999)
	})
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)

	// Those aborts each landed coins at the realm that the transaction
	// then reverted. In the harness the send is simulated rather than
	// rolled back, so the excess shows up as surplus; assert it is
	// EXACTLY surplus and has not leaked into escrow or a balance.
	appInvariant(t)
	if EscrowTotal() != b.escrow {
		t.Fatalf("a rejected purchase moved escrow: %d -> %d", b.escrow, EscrowTotal())
	}
	if UsersTotal() != b.users {
		t.Fatalf("a rejected purchase credited a balance")
	}
}

// Retiring stops NEW orders and nothing else. An order already in
// flight keeps its own copy of provider, amount and fee.
func TestRetireService(cur realm, t *testing.T) {
	b := begin()
	n0 := ServicesOf(prov1)
	p0 := BalanceOf(prov1)
	sid := registerAs(cur, prov1, "consulting", "one hour", 400000, 20000)
	oid := purchaseAs(cur, cust1, sid, 400000)

	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the provider may retire this service", func() {
		RetireService(cross(cur), sid)
	})

	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	RetireService(cross(cur), sid)
	_, _, _, _, _, status, _ := ServiceInfo(sid)
	if status != ServiceRetired {
		t.Fatalf("status = %s", status)
	}
	if ServicesOf(prov1) != n0 {
		t.Fatalf("retire did not free the provider slot: %d -> %d", n0, ServicesOf(prov1))
	}

	// Terminal: no un-retire, and no second retire.
	uassert.AbortsWithMessage(t, cur, "service is not active", func() {
		RetireService(cross(cur), sid)
	})

	// New orders refused...
	testing.SetRealm(testing.NewUserRealm(cust2))
	testing.SetOriginCaller(cust2)
	testing.SetOriginSend(ugnot(400000))
	testing.IssueCoins(Address(), ugnot(400000))
	uassert.AbortsWithMessage(t, cur, "service is not active", func() {
		PurchaseService(cross(cur), sid)
	})

	// ...but the in-flight order still completes normally.
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), oid, "notes.pdf")
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)
	AcceptDelivery(cross(cur), oid)
	_, _, _, _, _, ostatus := OrderInfo(oid)
	if ostatus != OrderReleased {
		t.Fatalf("in-flight order broke on retire: %s", ostatus)
	}
	if BalanceOf(prov1) != p0+400000 {
		t.Fatalf("provider credited %d, want %d", BalanceOf(prov1)-p0, 400000)
	}
	appInvariant(t)
	// The refused cust2 purchase landed its 400000 at the realm; on chain
	// the abort reverts that send, but the harness simulates it rather
	// than rolling it back, so it surfaces as out-of-band surplus. It is
	// asserted as surplus precisely to prove it did NOT reach escrow or a
	// balance.
	b.conserved(t, 400000)
}

func TestServiceCapPerProvider(cur realm, t *testing.T) {
	b := begin()
	ids := make([]int64, 0, MaxServicesPerProvider)
	for i := 0; i < MaxServicesPerProvider; i++ {
		ids = append(ids, registerAs(cur, prov2, "svc", "d", 1000, MinDeliveryBlocks))
	}
	if ServicesOf(prov2) != MaxServicesPerProvider {
		t.Fatalf("ServicesOf = %d", ServicesOf(prov2))
	}
	testing.SetRealm(testing.NewUserRealm(prov2))
	testing.SetOriginCaller(prov2)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "services per provider", func() {
		RegisterService(cross(cur), "one too many", "d", 1000, MinDeliveryBlocks, MaxFeeBps)
	})

	// Retiring frees exactly one slot.
	RetireService(cross(cur), ids[0])
	ids = append(ids, registerAs(cur, prov2, "replacement", "d", 1000, MinDeliveryBlocks))
	testing.SetRealm(testing.NewUserRealm(prov2))
	testing.SetOriginCaller(prov2)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "services per provider", func() {
		RegisterService(cross(cur), "still too many", "d", 1000, MinDeliveryBlocks, MaxFeeBps)
	})

	// The cap is per provider, not global.
	registerAs(cur, prov1, "unaffected", "d", 1000, MinDeliveryBlocks)

	// Teardown: realm globals persist between tests in this harness, so
	// leaving prov2 pinned at the cap would silently break every later
	// test that registers as prov2. Retire everything this test opened.
	testing.SetRealm(testing.NewUserRealm(prov2))
	testing.SetOriginCaller(prov2)
	testing.SetOriginSend(nil)
	for _, id := range ids[1:] {
		RetireService(cross(cur), id)
	}
	if ServicesOf(prov2) != 0 {
		t.Fatalf("teardown left %d services on prov2", ServicesOf(prov2))
	}
	appInvariant(t)
	b.conserved(t, 0)
}

// ---- the three required protections ----

// UNAUTHORIZED SETTLEMENT. Nobody but the customer can resolve a
// delivered order early — not the provider who did the work, not the
// admin, not the fee recipient, not a stranger, not another realm.
func TestUnauthorizedSettlement(cur realm, t *testing.T) {
	b := begin()
	p0 := BalanceOf(prov1)
	sid := registerAs(cur, prov1, "audit work", "review the thing", 1000000, 20000)
	oid := purchaseAs(cur, cust1, sid, 1000000)

	// Only the provider may mark delivered.
	for _, bad := range []address{cust1, testAdmin, mallory, prov2} {
		testing.SetRealm(testing.NewUserRealm(bad))
		testing.SetOriginCaller(bad)
		testing.SetOriginSend(nil)
		uassert.AbortsWithMessage(t, cur, "only the provider may mark this order delivered", func() {
			MarkDelivered(cross(cur), oid, "x")
		})
	}
	// Not even from another code realm.
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/attacker"))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the provider may mark this order delivered", func() {
		MarkDelivered(cross(cur), oid, "x")
	})

	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), oid, "ipfs://report")

	// Only the customer may accept. THE key authorization.
	for _, bad := range []address{prov1, testAdmin, mallory, cust2} {
		testing.SetRealm(testing.NewUserRealm(bad))
		testing.SetOriginCaller(bad)
		testing.SetOriginSend(nil)
		uassert.AbortsWithMessage(t, cur, "only the customer may accept this delivery", func() {
			AcceptDelivery(cross(cur), oid)
		})
	}
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/attacker"))
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the customer may accept this delivery", func() {
		AcceptDelivery(cross(cur), oid)
	})

	// The timeout valve is permissionless but NOT early: even the
	// provider cannot pull it before the window lapses.
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "acceptance window has not lapsed", func() {
		ReleaseTimeout(cross(cur), oid)
	})

	// Nothing has moved.
	if BalanceOf(prov1) != p0 {
		t.Fatalf("provider credited without resolution: %d -> %d", p0, BalanceOf(prov1))
	}
	if EscrowTotal()-b.escrow != 1000000 {
		t.Fatalf("escrow moved: ΔE=%d", EscrowTotal()-b.escrow)
	}

	// The customer, and only the customer, resolves it.
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)
	AcceptDelivery(cross(cur), oid)
	if BalanceOf(prov1)-p0 != 1000000 {
		t.Fatalf("provider credited %d, want 1000000 at 0 bps", BalanceOf(prov1)-p0)
	}
	appInvariant(t)
	b.conserved(t, 0)
}

// There is no admin path to escrow at all. The admin's only powers are
// the fee for FUTURE services, the fee recipient, and succession.
func TestAdminCannotTouchEscrow(cur realm, t *testing.T) {
	b := begin()
	sid := registerAs(cur, prov1, "held work", "d", 700000, 20000)
	oid := purchaseAs(cur, cust1, sid, 700000)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the provider may mark this order delivered", func() {
		MarkDelivered(cross(cur), oid, "x")
	})
	uassert.AbortsWithMessage(t, cur, "only the provider may decline this order", func() {
		DeclineOrder(cross(cur), oid)
	})
	uassert.AbortsContains(t, cur, "delivery window has not lapsed", func() {
		ClaimRefund(cross(cur), oid)
	})

	// And sweep cannot reach live escrow: the reserve covers E too.
	testing.IssueCoins(Address(), ugnot(12345)) // genuine out-of-band surplus
	before := coinsOf(testAdmin)
	SweepDenom(cross(cur), Denom)
	if got := coinsOf(testAdmin) - before; got != 12345 {
		t.Fatalf("swept %d, want exactly the 12345 surplus", got)
	}
	if EscrowTotal() != b.escrow+700000 {
		t.Fatalf("sweep reached escrow: %d", EscrowTotal())
	}
	appInvariant(t)
}

// DOUBLE PAYMENT. Every terminal transition is reachable at most once,
// and the two terminal outcomes are mutually exclusive.
func TestNoDoublePayment(cur realm, t *testing.T) {
	b := begin()
	sid := registerAs(cur, prov1, "double check", "d", 600000, 20000)

	// Accept twice.
	oid := purchaseAs(cur, cust1, sid, 600000)
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), oid, "v1")
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)
	AcceptDelivery(cross(cur), oid)
	credited := BalanceOf(prov1)
	uassert.AbortsWithMessage(t, cur, "order is not awaiting acceptance", func() {
		AcceptDelivery(cross(cur), oid)
	})
	if BalanceOf(prov1) != credited {
		t.Fatalf("second accept paid again: %d -> %d", credited, BalanceOf(prov1))
	}

	// Released orders cannot then be refunded, timed out, or re-delivered.
	uassert.AbortsWithMessage(t, cur, "order is not awaiting acceptance", func() {
		ReleaseTimeout(cross(cur), oid)
	})
	uassert.AbortsWithMessage(t, cur, "order is not awaiting delivery", func() {
		ClaimRefund(cross(cur), oid)
	})
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "order is not awaiting delivery", func() {
		DeclineOrder(cross(cur), oid)
	})
	uassert.AbortsWithMessage(t, cur, "order is not awaiting delivery", func() {
		MarkDelivered(cross(cur), oid, "v2")
	})

	// Decline twice, and a declined order cannot then be released.
	oid2 := purchaseAs(cur, cust2, sid, 600000)
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	DeclineOrder(cross(cur), oid2)
	refunded := BalanceOf(cust2)
	uassert.AbortsWithMessage(t, cur, "order is not awaiting delivery", func() {
		DeclineOrder(cross(cur), oid2)
	})
	if BalanceOf(cust2) != refunded {
		t.Fatalf("second decline refunded again")
	}
	testing.SetRealm(testing.NewUserRealm(cust2))
	testing.SetOriginCaller(cust2)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "order is not awaiting acceptance", func() {
		AcceptDelivery(cross(cur), oid2)
	})
	appInvariant(t)
	b.conserved(t, 0)
}

// A claim pays out once; the ledger is debited before coins move.
func TestNoDoubleClaim(cur realm, t *testing.T) {
	b := begin()
	p0 := BalanceOf(prov1) // carried in from earlier tests; ClaimAll drains it too
	sid := registerAs(cur, prov1, "claim once", "d", 800000, 20000)
	oid := purchaseAs(cur, cust1, sid, 800000)
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), oid, "done")
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)
	AcceptDelivery(cross(cur), oid)

	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	before := coinsOf(prov1)
	ClaimAll(cross(cur))
	if got := coinsOf(prov1) - before; got != p0+800000 {
		t.Fatalf("claimed %d, want %d", got, p0+800000)
	}
	if BalanceOf(prov1) != 0 {
		t.Fatal("balance not zeroed")
	}
	uassert.AbortsWithMessage(t, cur, "nothing to claim", func() {
		ClaimAll(cross(cur))
	})
	uassert.AbortsContains(t, cur, "insufficient", func() {
		Claim(cross(cur), 1)
	})
	if got := coinsOf(prov1) - before; got != p0+800000 {
		t.Fatalf("a second claim paid out: total %d", got)
	}
	appInvariant(t)
	b.conserved(t, 0)
}

// STUCK FUNDS, arm 1: the provider abandons the order. Anyone may
// return the escrow to the customer once the delivery window lapses.
func TestStuckFundsProviderAbandons(cur realm, t *testing.T) {
	b := begin()
	sid := registerAs(cur, prov1, "never delivered", "d", 900000, MinDeliveryBlocks)
	oid := purchaseAs(cur, cust1, sid, 900000)

	// Too early, even for the customer.
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "delivery window has not lapsed", func() {
		ClaimRefund(cross(cur), oid)
	})

	testing.SkipHeights(MinDeliveryBlocks)

	// A total stranger pulls the valve; the money goes to the CUSTOMER,
	// not to the caller.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	mBefore := BalanceOf(mallory)
	ClaimRefund(cross(cur), oid)
	if BalanceOf(mallory) != mBefore {
		t.Fatal("the valve paid its caller")
	}
	if BalanceOf(cust1) != 900000 {
		t.Fatalf("customer refund = %d, want 900000", BalanceOf(cust1))
	}
	if FeesAccrued() != b.fees {
		t.Fatal("a refund accrued a protocol fee")
	}
	_, _, _, _, _, status := OrderInfo(oid)
	if status != OrderRefunded {
		t.Fatalf("status = %s", status)
	}
	// And the customer can actually get the coins out.
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)
	before := coinsOf(cust1)
	ClaimAll(cross(cur))
	if got := coinsOf(cust1) - before; got != 900000 {
		t.Fatalf("customer withdrew %d", got)
	}
	appInvariant(t)
	b.conserved(t, 0)
}

// STUCK FUNDS, arm 2: the customer goes silent after delivery. Anyone
// may release the escrow to the provider once acceptance lapses. This
// is the valve whose polarity is INVERTED from every sibling realm's,
// and getting it wrong would strand completed work.
func TestStuckFundsCustomerGoesSilent(cur realm, t *testing.T) {
	b := begin()
	sid := registerAs(cur, prov1, "delivered ignored", "d", 1000000, MaxDeliveryBlocks)
	oid := purchaseAs(cur, cust1, sid, 1000000)
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), oid, "ipfs://final")

	_, acceptanceDeadline := OrderDeadlines(oid)
	if acceptanceDeadline != Height()+AcceptanceBlocks {
		t.Fatalf("acceptance deadline = %d, want height+%d", acceptanceDeadline, AcceptanceBlocks)
	}

	testing.SkipHeights(AcceptanceBlocks)

	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	mBefore := BalanceOf(mallory)
	ReleaseTimeout(cross(cur), oid)
	if BalanceOf(mallory) != mBefore {
		t.Fatal("the valve paid its caller")
	}
	if BalanceOf(prov1) != 1000000 {
		t.Fatalf("provider = %d, want 1000000", BalanceOf(prov1))
	}
	_, _, _, _, _, status := OrderInfo(oid)
	if status != OrderReleased {
		t.Fatalf("status = %s", status)
	}
	appInvariant(t)
	b.conserved(t, 0)
}

// The delivery deadline protects the customer, so late delivery is
// allowed while the refund valve is still un-pulled — but the refund
// valve closes the instant delivery lands, and reopening it is not
// possible.
func TestLateDeliveryRace(cur realm, t *testing.T) {
	b := begin()
	p0 := BalanceOf(prov1)
	sid := registerAs(cur, prov1, "late but wanted", "d", 500000, MinDeliveryBlocks)
	oid := purchaseAs(cur, cust1, sid, 500000)

	testing.SkipHeights(MinDeliveryBlocks + 10)

	// Provider delivers late; permitted.
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), oid, "late.zip")

	// The refund valve is now closed: the order is no longer awaiting
	// delivery, so the lapsed delivery deadline is irrelevant.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "order is not awaiting delivery", func() {
		ClaimRefund(cross(cur), oid)
	})
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "order is not awaiting delivery", func() {
		ClaimRefund(cross(cur), oid)
	})

	// The customer still holds the real lever: accept, or wait out the
	// acceptance window.
	AcceptDelivery(cross(cur), oid)
	if BalanceOf(prov1)-p0 != 500000 {
		t.Fatalf("provider credited %d, want 500000", BalanceOf(prov1)-p0)
	}
	appInvariant(t)
	b.conserved(t, 0)
}

// ---- fees, sweep, administration ----

func TestFeeSplitAndWithdraw(cur realm, t *testing.T) {
	b := begin()
	p0 := BalanceOf(prov1)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), 250) // 2.5%

	sid := registerAs(cur, prov1, "fee bearing", "d", 1000000, 20000)
	p, fee, toProvider := Quote(sid)
	if p != 1000000 || fee != 25000 || toProvider != 975000 {
		t.Fatalf("Quote = %d/%d/%d", p, fee, toProvider)
	}

	oid := purchaseAs(cur, cust1, sid, 1000000)
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), oid, "x")
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)
	AcceptDelivery(cross(cur), oid)

	if BalanceOf(prov1)-p0 != 975000 {
		t.Fatalf("provider credited %d, want 975000", BalanceOf(prov1)-p0)
	}
	if FeesAccrued()-b.fees != 25000 {
		t.Fatalf("fee pot ΔF = %d", FeesAccrued()-b.fees)
	}

	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the fee recipient may withdraw fees", func() {
		WithdrawFees(cross(cur))
	})
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	before := coinsOf(testAdmin)
	WithdrawFees(cross(cur))
	if got := coinsOf(testAdmin) - before; got != b.fees+25000 {
		t.Fatalf("withdrew %d", got)
	}
	uassert.AbortsWithMessage(t, cur, "no fees accrued", func() {
		WithdrawFees(cross(cur))
	})

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), 0)
	appInvariant(t)
	b.conserved(t, 0)
}

func TestSweepReservesEscrow(cur realm, t *testing.T) {
	b := begin()
	sid := registerAs(cur, prov1, "sweep guard", "d", 400000, 20000)
	purchaseAs(cur, cust1, sid, 400000)

	// No surplus yet. coinio.Sweep aborts rather than sending zero, so
	// the escrow is unreachable by REVERT, not merely by arithmetic —
	// which is the stronger of the two.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	before := coinsOf(testAdmin)
	uassert.AbortsContains(t, cur, "no surplus to sweep", func() {
		SweepDenom(cross(cur), Denom)
	})
	if coinsOf(testAdmin) != before {
		t.Fatal("swept out of a zero-surplus realm")
	}
	if EscrowTotal() != b.escrow+400000 {
		t.Fatal("sweep reached escrow")
	}

	// A foreign denom moves wholly.
	testing.IssueCoins(Address(), chain.NewCoins(chain.NewCoin("gjunk", 77)))
	SweepDenom(cross(cur), "gjunk")
	if banker.NewReadonlyBanker().GetCoin(testAdmin, "gjunk") != 77 {
		t.Fatal("foreign denom not swept")
	}

	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the fee recipient may sweep surplus", func() {
		SweepDenom(cross(cur), Denom)
	})
	appInvariant(t)
}

func TestAdminHandover(cur realm, t *testing.T) {
	b := begin()
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		TransferAdmin(cross(cur), mallory)
	})
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		SetFeeBps(cross(cur), 10)
	})
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		SetFeeRecipient(cross(cur), mallory)
	})

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	// A malformed nominee is rejected where the typo is made, for parity
	// with SetFeeRecipient. The zero address keeps its documented meaning
	// as the cancel sentinel and must NOT be caught by that check.
	uassert.AbortsWithMessage(t, cur, "invalid admin address", func() {
		TransferAdmin(cross(cur), address("g1notanaddress"))
	})
	TransferAdmin(cross(cur), prov2)
	if Admin() != testAdmin {
		t.Fatal("nomination took effect immediately")
	}
	if PendingAdmin() != prov2 {
		t.Fatalf("pending = %v", PendingAdmin())
	}
	TransferAdmin(cross(cur), "")
	if PendingAdmin() != "" {
		t.Fatalf("zero address did not cancel: %v", PendingAdmin())
	}
	TransferAdmin(cross(cur), prov2)

	// Wrong acceptor.
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "only the nominated admin may accept", func() {
		AcceptAdmin(cross(cur))
	})
	testing.SetRealm(testing.NewUserRealm(prov2))
	testing.SetOriginCaller(prov2)
	testing.SetOriginSend(nil)
	AcceptAdmin(cross(cur))
	if Admin() != prov2 {
		t.Fatalf("admin = %v", Admin())
	}
	var zero address
	if PendingAdmin() != zero {
		t.Fatal("pending not cleared")
	}

	// Authority MOVED: the former admin is now powerless.
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "admin only", func() {
		SetFeeBps(cross(cur), 10)
	})

	// Hand it back so the rest of the suite keeps its seeded roles.
	testing.SetRealm(testing.NewUserRealm(prov2))
	testing.SetOriginCaller(prov2)
	testing.SetOriginSend(nil)
	TransferAdmin(cross(cur), testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	AcceptAdmin(cross(cur))
	if Admin() != testAdmin {
		t.Fatal("handback failed")
	}
	appInvariant(t)
	b.conserved(t, 0)
}

// ---- render safety ----

func TestRenderSanitizesUntrustedText(cur realm, t *testing.T) {
	begin()
	evil := "[click](https://evil.example) ![x](https://evil.example/x.png)"
	sid := registerAs(cur, prov1, "render probe", evil, 100000, 20000)
	oid := purchaseAs(cur, cust1, sid, 100000)
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), oid, evil)

	sOut := Render("s/" + itoa(sid))
	if strings.Contains(sOut, "](https://evil.example)") {
		t.Fatal("service description rendered an unescaped markdown link")
	}
	oOut := Render("o/" + itoa(oid))
	if strings.Contains(oOut, "](https://evil.example/x.png)") {
		t.Fatal("delivery uri rendered an unescaped markdown image")
	}

	// Unknown and malformed ids degrade to a warning, never a panic.
	for _, p := range []string{"s/abc", "o/abc", "s/999999", "o/999999"} {
		if !strings.Contains(Render(p), "[!WARNING]") {
			t.Fatalf("Render(%q) did not warn", p)
		}
	}
	if !strings.Contains(Render(""), "Service marketplace") {
		t.Fatal("home render broken")
	}
	appInvariant(t)
}

// The home page is bounded regardless of catalog size.
func TestRenderIsBounded(cur realm, t *testing.T) {
	begin()
	for i := 0; i < RenderLimit+5; i++ {
		registerAs(cur, prov2, "bulk svc", "d", 1000, MinDeliveryBlocks)
		testing.SetRealm(testing.NewUserRealm(prov2))
		testing.SetOriginCaller(prov2)
		testing.SetOriginSend(nil)
		// Retire immediately so the per-provider cap is not the thing
		// under test here.
		RetireService(cross(cur), NumServices()-1)
	}
	out := Render("")
	if got := strings.Count(out, "\n- [#"); got > RenderLimit {
		t.Fatalf("home listed %d services, cap is %d", got, RenderLimit)
	}
	appInvariant(t)
}

// ---- guards on every non-payable entrypoint ----

func TestNonPayableEntrypointsRefuseCoins(cur realm, t *testing.T) {
	b := begin()
	sid := registerAs(cur, prov1, "send guard", "d", 100000, 20000)
	oid := purchaseAs(cur, cust1, sid, 100000)

	stage := func(from address) {
		testing.SetRealm(testing.NewUserRealm(from))
		testing.SetOriginCaller(from)
		testing.SetOriginSend(ugnot(1))
	}
	msg := "this function does not accept coins"

	stage(prov1)
	uassert.AbortsWithMessage(t, cur, msg, func() { MarkDelivered(cross(cur), oid, "x") })
	uassert.AbortsWithMessage(t, cur, msg, func() { DeclineOrder(cross(cur), oid) })
	uassert.AbortsWithMessage(t, cur, msg, func() { RetireService(cross(cur), sid) })
	uassert.AbortsWithMessage(t, cur, msg, func() { ClaimAll(cross(cur)) })
	uassert.AbortsWithMessage(t, cur, msg, func() { Claim(cross(cur), 1) })
	stage(cust1)
	uassert.AbortsWithMessage(t, cur, msg, func() { AcceptDelivery(cross(cur), oid) })
	uassert.AbortsWithMessage(t, cur, msg, func() { ClaimRefund(cross(cur), oid) })
	uassert.AbortsWithMessage(t, cur, msg, func() { ReleaseTimeout(cross(cur), oid) })
	stage(testAdmin)
	uassert.AbortsWithMessage(t, cur, msg, func() { SetFeeBps(cross(cur), 1) })
	uassert.AbortsWithMessage(t, cur, msg, func() { SetFeeRecipient(cross(cur), prov1) })
	uassert.AbortsWithMessage(t, cur, msg, func() { TransferAdmin(cross(cur), prov1) })
	uassert.AbortsWithMessage(t, cur, msg, func() { AcceptAdmin(cross(cur)) })
	uassert.AbortsWithMessage(t, cur, msg, func() { WithdrawFees(cross(cur)) })
	uassert.AbortsWithMessage(t, cur, msg, func() { SweepDenom(cross(cur), Denom) })

	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	appInvariant(t)
	if EscrowTotal() != b.escrow+100000 {
		t.Fatal("a refused call moved escrow")
	}
}

func TestUnknownIdsAbort(cur realm, t *testing.T) {
	begin()
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	uassert.AbortsWithMessage(t, cur, "unknown service id", func() {
		RetireService(cross(cur), 999999)
	})
	uassert.AbortsWithMessage(t, cur, "unknown order id", func() {
		AcceptDelivery(cross(cur), 999999)
	})
	uassert.AbortsWithMessage(t, cur, "unknown order id", func() {
		ClaimRefund(cross(cur), 999999)
	})
	uassert.AbortsWithMessage(t, cur, "unknown order id", func() {
		ReleaseTimeout(cross(cur), 999999)
	})
	// A view is not a crossing call, so its failure is a plain panic
	// rather than an abort — a different assertion, not a weaker one.
	uassert.PanicsWithMessage(t, cur, "unknown service id", func() {
		ServiceDescription(999999)
	})
	uassert.PanicsWithMessage(t, cur, "unknown order id", func() {
		OrderInfo(999999)
	})
}

func TestMarkDeliveredBoundsURI(cur realm, t *testing.T) {
	begin()
	sid := registerAs(cur, prov1, "uri bound", "d", 100000, 20000)
	oid := purchaseAs(cur, cust1, sid, 100000)
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "uri must be at most", func() {
		MarkDelivered(cross(cur), oid, strings.Repeat("u", MaxURILen+1))
	})
	MarkDelivered(cross(cur), oid, strings.Repeat("u", MaxURILen))
	if len(OrderURI(oid)) != MaxURILen {
		t.Fatal("uri not stored at the boundary")
	}
	appInvariant(t)
}

func TestCheckedAddOverflow(t *testing.T) {
	const maxInt64 int64 = 1<<63 - 1
	if _, ok := checkedAdd(maxInt64, 1); ok {
		t.Fatal("overflow not detected")
	}
	if v, ok := checkedAdd(maxInt64-1, 1); !ok || v != maxInt64 {
		t.Fatal("boundary add rejected")
	}
	if v, ok := checkedAdd(5, -3); !ok || v != 2 {
		t.Fatal("negative delta broken")
	}
}

// A full multi-party run, asserting conservation at every checkpoint —
// the property that all three protections ultimately rest on.
func TestFullLifecycleConservation(cur realm, t *testing.T) {
	b := begin()
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), 100) // 1%

	s1 := registerAs(cur, prov1, "alpha", "d", 1000000, MinDeliveryBlocks)
	s2 := registerAs(cur, prov2, "beta", "d", 2000000, MaxDeliveryBlocks)
	b.conserved(t, 0)

	// Accepted.
	o1 := purchaseAs(cur, cust1, s1, 1000000)
	b.conserved(t, 0)
	testing.SetRealm(testing.NewUserRealm(prov1))
	testing.SetOriginCaller(prov1)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), o1, "a")
	testing.SetRealm(testing.NewUserRealm(cust1))
	testing.SetOriginCaller(cust1)
	testing.SetOriginSend(nil)
	AcceptDelivery(cross(cur), o1)
	b.conserved(t, 0)

	// Declined.
	o2 := purchaseAs(cur, cust2, s2, 2000000)
	testing.SetRealm(testing.NewUserRealm(prov2))
	testing.SetOriginCaller(prov2)
	testing.SetOriginSend(nil)
	DeclineOrder(cross(cur), o2)
	b.conserved(t, 0)

	// Expired to a refund.
	o3 := purchaseAs(cur, cust1, s1, 1000000)
	testing.SkipHeights(MinDeliveryBlocks)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	ClaimRefund(cross(cur), o3)
	b.conserved(t, 0)

	// Timed out to a release.
	o4 := purchaseAs(cur, cust2, s2, 2000000)
	testing.SetRealm(testing.NewUserRealm(prov2))
	testing.SetOriginCaller(prov2)
	testing.SetOriginSend(nil)
	MarkDelivered(cross(cur), o4, "b")
	testing.SkipHeights(AcceptanceBlocks)
	testing.SetRealm(testing.NewUserRealm(mallory))
	testing.SetOriginCaller(mallory)
	testing.SetOriginSend(nil)
	ReleaseTimeout(cross(cur), o4)
	b.conserved(t, 0)

	if EscrowTotal() != b.escrow {
		t.Fatalf("escrow not drained: %d -> %d", b.escrow, EscrowTotal())
	}

	// Everyone withdraws; the realm ends holding only what it started
	// with plus the fee pot it still owes.
	for _, who := range []address{prov1, prov2, cust1, cust2, testAdmin, mallory} {
		if BalanceOf(who) == 0 {
			continue
		}
		testing.SetRealm(testing.NewUserRealm(who))
		testing.SetOriginCaller(who)
		testing.SetOriginSend(nil)
		ClaimAll(cross(cur))
	}
	// Every counterparty this suite has ever used is in that list, so
	// draining them must take U to exactly zero — not back to the
	// baseline, which still carried earlier tests' unclaimed credits.
	if UsersTotal() != 0 {
		t.Fatalf("claimable residue: %d", UsersTotal())
	}
	appInvariant(t)
	b.conserved(t, 0)

	testing.SetRealm(testing.NewUserRealm(testAdmin))
	testing.SetOriginCaller(testAdmin)
	testing.SetOriginSend(nil)
	SetFeeBps(cross(cur), 0)
}
