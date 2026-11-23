package agentvault

import (
	"strings"
	"testing"

	"chain"
	"chain/banker"

	caps "gno.land/p/g16740fm9kd28luuktn3g42jfq3r998fm35chclv/agentvault"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// resetVault restores every package-level var to a fresh state.
// gno test reuses one machine per package, so state persists across
// test functions unless reset. This helper touches state only, so it
// is safe to call from anywhere.
//
// NOTE on testing.SetRealm: in gno test, SetRealm's effect is visible
// only to cross calls made in the same function frame (and functions
// called from it while it is active). A SetRealm inside a helper that
// returns before the cross call is lost: the caller stays stuck at
// whatever realm was set earlier. So every test below calls
// testing.SetRealm directly, immediately before each cross call.
// Never wrap SetRealm in a helper (asUser/setupVault did that and
// every multi-caller test failed with a stale caller).
func resetVault() {
	owner = ""
	budgets = make(map[address]caps.AgentBudget)
	agentList = nil
	nameMap = make(map[string]address)
	attempts = nil
	escrows = make(map[int64]caps.Escrow)
	nextEscrowID = 1
	nextAttemptID = 1
	totalFunded = 0
	totalSpent = 0
	escrowedTotal = 0
}

// fundRealm credits the realm in the test bank and mirrors it in the
// tracked total, so AvailableBalance agrees with the real balance.
// No SetRealm and no cross call, so it is safe as a helper.
func fundRealm() {
	testing.IssueCoins(selfAddr, chain.Coins{{Denom: "ugnot", Amount: 10000000}})
	totalFunded = 10000000
}

func balanceOf(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, denom)
}

func TestSpendWithinCaps(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	agent := testutils.TestAddress("agent")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetCap(cross(cur), agent, 100, 1000)

	before := balanceOf(agent)
	testing.SetRealm(testing.NewUserRealm(agent))
	ok, reason := Spend(cross(cur), 50, "test run")
	if !ok {
		t.Fatal("spend within caps rejected:", reason)
	}
	if balanceOf(agent)-before != 50 {
		t.Fatal("agent did not receive the spend")
	}
	b, _ := Budget(agent)
	if b.SpentToday != 50 {
		t.Fatal("spent today not recorded:", b.SpentToday)
	}
	if totalSpent != 50 {
		t.Fatal("total spent not recorded:", totalSpent)
	}
	if len(Attempts()) != 1 || !Attempts()[0].Allowed {
		t.Fatal("spend not logged as allowed")
	}
}

func TestSpendOverPerTxCap(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	agent := testutils.TestAddress("agent")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetCap(cross(cur), agent, 100, 1000)

	// The demo moment: 10x the per-transaction cap.
	before := balanceOf(agent)
	testing.SetRealm(testing.NewUserRealm(agent))
	ok, reason := Spend(cross(cur), 1000, "overspend demo")
	if ok {
		t.Fatal("10x overspend allowed")
	}
	if reason != "exceeds per-transaction cap" {
		t.Fatal("wrong rejection reason:", reason)
	}
	if balanceOf(agent) != before {
		t.Fatal("blocked spend moved coins")
	}
	b, _ := Budget(agent)
	if b.SpentToday != 0 {
		t.Fatal("blocked spend recorded as spent")
	}
	at := Attempts()
	if len(at) != 1 || at[0].Allowed || at[0].Reason != "exceeds per-transaction cap" {
		t.Fatal("blocked spend not logged with its reason")
	}
}

func TestSpendOverDailyCap(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	agent := testutils.TestAddress("agent")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetCap(cross(cur), agent, 1000, 1000)

	testing.SetRealm(testing.NewUserRealm(agent))
	// Spend 600 of the 1000 daily cap.
	if ok, _ := Spend(cross(cur), 600, "first"); !ok {
		t.Fatal("first spend rejected")
	}
	// Another 500 would take the day to 1100: blocked by the daily cap.
	testing.SetRealm(testing.NewUserRealm(agent))
	ok, reason := Spend(cross(cur), 500, "second")
	if ok {
		t.Fatal("spend over daily cap allowed")
	}
	if reason != "exceeds daily cap" {
		t.Fatal("wrong rejection reason:", reason)
	}
	// Exactly the remainder is allowed.
	testing.SetRealm(testing.NewUserRealm(agent))
	if ok, reason := Spend(cross(cur), 400, "remainder"); !ok {
		t.Fatal("spend at daily remainder rejected:", reason)
	}
}

func TestSpendNoBudget(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	agent := testutils.TestAddress("agent")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()

	testing.SetRealm(testing.NewUserRealm(agent))
	ok, reason := Spend(cross(cur), 10, "no budget")
	if ok {
		t.Fatal("spend without a budget allowed")
	}
	if reason != "no budget set for this agent" {
		t.Fatal("wrong rejection reason:", reason)
	}
	if len(Attempts()) != 1 || Attempts()[0].Allowed {
		t.Fatal("unbudgeted spend not logged as blocked")
	}
}

func TestSpendInsufficientBalance(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	agent := testutils.TestAddress("agent")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetCap(cross(cur), agent, 100000, 100000)
	// Hold (nearly) everything in escrow by direct state setup, so
	// the available balance is ~0 regardless of the test bank total.
	escrowedTotal = VaultBalance()
	testing.SetRealm(testing.NewUserRealm(agent))
	ok, reason := Spend(cross(cur), 10, "empty vault")
	if ok {
		t.Fatal("spend with no available balance allowed")
	}
	if reason != "insufficient vault balance" {
		t.Fatal("wrong rejection reason:", reason)
	}
}

func TestDailyReset(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	agent := testutils.TestAddress("agent")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetCap(cross(cur), agent, 100, 1000)
	// Simulate yesterday's spend: the budget's day is one behind the
	// test machine's fixed time (unix 1234567890 -> day 14288).
	b, _ := Budget(agent)
	b.SpentToday = 900
	b.DayIndex = 14287
	budgets[agent] = b

	// A 50 spend would exceed the daily cap on yesterday's books,
	// but the day has rolled over, so it must be allowed.
	testing.SetRealm(testing.NewUserRealm(agent))
	ok, reason := Spend(cross(cur), 50, "new day")
	if !ok {
		t.Fatal("spend on a new day rejected:", reason)
	}
	b2, _ := Budget(agent)
	if b2.SpentToday != 50 {
		t.Fatal("spent today not reset then recorded:", b2.SpentToday)
	}
	if b2.DayIndex != 14288 {
		t.Fatal("day index not advanced:", b2.DayIndex)
	}
}

func TestEscrowConfirm(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	recipient := testutils.TestAddress("recipient")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetName(cross(cur), "nym-george123", recipient)

	// Owner pays the named agent; the payment is held.
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	id, ok, reason := PayByName(cross(cur), "nym-george123", 500, 100)
	if !ok {
		t.Fatal("pay by name failed:", reason)
	}
	if EscrowedTotal() != 500 {
		t.Fatal("escrowed total not recorded:", EscrowedTotal())
	}
	if AvailableBalance() != VaultBalance()-500 {
		t.Fatal("available balance did not drop by the escrow")
	}
	e, found := Escrow(id)
	if !found || e.Status != caps.EscrowHeld {
		t.Fatal("escrow not held after creation")
	}
	if e.Recipient != recipient || e.RecipientName != "nym-george123" {
		t.Fatal("escrow recipient wrong")
	}

	// A stranger cannot confirm it.
	stranger := testutils.TestAddress("stranger")
	testing.SetRealm(testing.NewUserRealm(stranger))
	if ok, reason := ConfirmEscrow(cross(cur), id); ok {
		t.Fatal("stranger confirmed the escrow")
	} else if reason != "only the recipient can confirm" {
		t.Fatal("wrong confirm rejection:", reason)
	}

	// The recipient confirms; the coins arrive and the escrow releases.
	before := balanceOf(recipient)
	testing.SetRealm(testing.NewUserRealm(recipient))
	ok, reason = ConfirmEscrow(cross(cur), id)
	if !ok {
		t.Fatal("recipient confirm failed:", reason)
	}
	if balanceOf(recipient)-before != 500 {
		t.Fatal("recipient did not receive the escrow")
	}
	if EscrowedTotal() != 0 {
		t.Fatal("escrowed total not freed on release")
	}
	e, _ = Escrow(id)
	if e.Status != caps.EscrowReleased {
		t.Fatal("escrow not released")
	}
	// Confirming again fails: it is no longer held.
	testing.SetRealm(testing.NewUserRealm(recipient))
	if ok, _ := ConfirmEscrow(cross(cur), id); ok {
		t.Fatal("released escrow confirmed again")
	}
}

func TestEscrowRefund(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	recipient := testutils.TestAddress("recipient")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetName(cross(cur), "nym-george123", recipient)
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	id, ok, reason := PayByName(cross(cur), "nym-george123", 300, 1000)
	if !ok {
		t.Fatal("pay by name failed:", reason)
	}

	// Before the deadline the owner cannot refund.
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	if ok, reason := RefundEscrow(cross(cur), id); ok {
		t.Fatal("refund before deadline allowed")
	} else if reason != "deadline has not passed" {
		t.Fatal("wrong refund rejection:", reason)
	}

	// Move the deadline into the past (the test machine's height is
	// fixed, so the deadline is set directly) and refund succeeds.
	e, _ := Escrow(id)
	e.DeadlineHeight = 1
	escrows[id] = e
	before := AvailableBalance()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	ok, reason = RefundEscrow(cross(cur), id)
	if !ok {
		t.Fatal("refund after deadline failed:", reason)
	}
	if AvailableBalance()-before != 300 {
		t.Fatal("refund did not free the held amount")
	}
	e, _ = Escrow(id)
	if e.Status != caps.EscrowRefunded {
		t.Fatal("escrow not refunded")
	}
	// Refunding again fails.
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	if ok, _ := RefundEscrow(cross(cur), id); ok {
		t.Fatal("refunded escrow refunded again")
	}
}

func TestPayByNameUnknown(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	id, ok, reason := PayByName(cross(cur), "nym-nobody999", 100, 10)
	if ok || id != -1 {
		t.Fatal("payment to an unknown name succeeded")
	}
	if reason != "name not found: nym-nobody999" {
		t.Fatal("wrong rejection reason:", reason)
	}
}

func TestNameResolution(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	recipient := testutils.TestAddress("recipient")
	// Unknown before it is registered.
	if _, ok := ResolveName("nym-george123"); ok {
		t.Fatal("unregistered name resolved")
	}
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetName(cross(cur), "nym-george123", recipient)
	if addr, ok := ResolveName("nym-george123"); !ok || addr != recipient {
		t.Fatal("local name map did not resolve")
	}
	// Caps can be set by name through the local map.
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetCapByName(cross(cur), "nym-george123", 200, 2000)
	b, ok := Budget(recipient)
	if !ok || b.PerTxCap != 200 || b.DailyCap != 2000 {
		t.Fatal("cap by name not applied to the resolved address")
	}
	b2, ok := BudgetByName("nym-george123")
	if !ok || b2.PerTxCap != 200 {
		t.Fatal("budget by name not found")
	}
	if _, ok := BudgetByName("nym-nobody999"); ok {
		t.Fatal("budget by unknown name found")
	}
}

func TestOwnerOnly(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	agent := testutils.TestAddress("agent")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()

	// A non-owner cannot set caps, names, or fund.
	testing.SetRealm(testing.NewUserRealm(agent))
	uassert.AbortsWithMessage(t, cur, "not the owner", func() {
		SetCap(cross(cur), agent, 100, 1000)
	})
	testing.SetRealm(testing.NewUserRealm(agent))
	uassert.AbortsWithMessage(t, cur, "not the owner", func() {
		SetName(cross(cur), "nym-x", agent)
	})
	testing.SetRealm(testing.NewUserRealm(agent))
	uassert.AbortsWithMessage(t, cur, "not the owner", func() {
		Fund(cross(cur))
	})
	testing.SetRealm(testing.NewUserRealm(agent))
	uassert.AbortsWithMessage(t, cur, "not the owner", func() {
		SetOwner(cross(cur), agent)
	})
	// The owner can set caps and rotate ownership.
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	uassert.NotAborts(t, cur, func() {
		SetCap(cross(cur), agent, 100, 1000)
	})
	newOwner := testutils.TestAddress("newowner")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	uassert.NotAborts(t, cur, func() {
		SetOwner(cross(cur), newOwner)
	})
	if Owner() != newOwner {
		t.Fatal("owner rotation failed")
	}
	// The old owner is now locked out.
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	uassert.AbortsWithMessage(t, cur, "not the owner", func() {
		SetCap(cross(cur), agent, 100, 1000)
	})
}

func TestSetCapPreservesSpent(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	agent := testutils.TestAddress("agent")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetCap(cross(cur), agent, 1000, 1000)
	testing.SetRealm(testing.NewUserRealm(agent))
	if ok, _ := Spend(cross(cur), 600, "first"); !ok {
		t.Fatal("setup spend failed")
	}
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	// Re-set the caps mid-day; the 600 already spent today must stay spent.
	SetCap(cross(cur), agent, 1000, 1000)
	b, _ := Budget(agent)
	if b.SpentToday != 600 {
		t.Fatal("re-setting caps reset the spent amount:", b.SpentToday)
	}
	// Only 400 of the daily cap remains.
	testing.SetRealm(testing.NewUserRealm(agent))
	if ok, reason := Spend(cross(cur), 500, "over remainder"); ok {
		t.Fatal("spend over the preserved remainder allowed")
	} else if reason != "exceeds daily cap" {
		t.Fatal("wrong rejection reason:", reason)
	}
}

func TestRender(cur realm, t *testing.T) {
	resetVault()
	ownerAddr := testutils.TestAddress("owner")
	agent := testutils.TestAddress("agent")
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetOwner(cross(cur), ownerAddr)
	fundRealm()
	testing.SetRealm(testing.NewUserRealm(ownerAddr))
	SetCap(cross(cur), agent, 100, 1000)
	testing.SetRealm(testing.NewUserRealm(agent))
	// One blocked overspend, so the page must show it.
	Spend(cross(cur), 1000, "overspend | demo #test")
	page := Render("")
	for _, want := range []string{
		"# AgentVault",
		"## Budgets",
		"## Guard report",
		"## Escrows",
		"## Spend log",
		"## Import the cap library",
		"gno.land/p/g16740fm9kd28luuktn3g42jfq3r998fm35chclv/agentvault",
		"**BLOCKED**",
		"exceeds per-transaction cap",
	} {
		if !strings.Contains(page, want) {
			t.Fatal("render page missing:", want)
		}
	}
	// The purpose carried a pipe and a hash; neither may survive raw
	// into the table or the markdown would break / inject.
	if strings.Contains(page, "overspend | demo") {
		t.Fatal("render page contains an unsanitized pipe in the purpose")
	}
}
