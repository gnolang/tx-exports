// Tests for Tavern Tab. They exercise the core logic functions
// directly (explicit caller addresses), so no chain context is needed.
// Valid bech32 g1 addresses below were generated offline.
package taverntab

import (
	"strconv"
	"strings"
	"testing"
)

var (
	alice = address("g1qypqxpq9qcrsszg2pvxq6rs0zqg3yyc5v7sa8c")
	bob   = address("g1z5tpwxqergd3c8g7ruszzg3rysjjvfegmmyn0w")
	carol = address("g19y4zktpd9chnqvfjxv6r2d3h8qun5weu6uewmy")
	dave  = address("g185lr7szpgfp5g32xgayyjjjtf3x5un6sq7lv6w")
)

func mustTab(t *testing.T, owner address, name string) int64 {
	id, err := createTab(owner, name)
	if err != "" {
		t.Fatalf("createTab failed: %s", err)
	}
	return id
}

func mustJoin(t *testing.T, who address, tabID int64) {
	if err := joinTab(who, tabID, ""); err != "" {
		t.Fatalf("joinTab failed: %s", err)
	}
}

func TestCreateTabAndJoin(t *testing.T) {
	id := mustTab(t, alice, "Friday Tavern")
	if id < 1 {
		t.Fatalf("bad tab id %d", id)
	}
	tab := tabs[findTabIndex(id)]
	if tab.Owner != alice {
		t.Fatalf("owner mismatch")
	}
	if len(tab.Members) != 1 {
		t.Fatalf("creator should be the only member, got %d", len(tab.Members))
	}
	mustJoin(t, bob, id)
	mustJoin(t, carol, id)
	if err := joinTab(bob, id, ""); err == "" {
		t.Fatalf("duplicate join should fail")
	}
	if err := addMember(bob, id, dave, ""); err == "" {
		t.Fatalf("non-owner AddMember should fail")
	}
	if err := addMember(alice, id, dave, "Dave"); err != "" {
		t.Fatalf("owner AddMember failed: %s", err)
	}
	if len(tabs[findTabIndex(id)].Members) != 4 {
		t.Fatalf("expected 4 members")
	}
}

func TestExpenseSplitRemainder(t *testing.T) {
	id := mustTab(t, alice, "Remainder Tab")
	mustJoin(t, bob, id)
	mustJoin(t, carol, id)
	parts := alice.String() + "," + bob.String() + "," + carol.String()
	expID, err := addExpense(alice, id, 1000, "first round", parts)
	if err != "" {
		t.Fatalf("addExpense failed: %s", err)
	}
	if expID != 1 {
		t.Fatalf("expected expense id 1, got %d", expID)
	}
	tab := tabs[findTabIndex(id)]
	e := tab.Expenses[0]
	if e.Share != 333 || e.Remainder != 1 {
		t.Fatalf("expected share 333 remainder 1, got %d / %d", e.Share, e.Remainder)
	}
	// Payer is credited amount - share - remainder = 666; others -333.
	if got := netBalance(tab, alice); got != 666 {
		t.Fatalf("alice net = %d, want 666", got)
	}
	if got := netBalance(tab, bob); got != -333 {
		t.Fatalf("bob net = %d, want -333", got)
	}
	if got := netBalance(tab, carol); got != -333 {
		t.Fatalf("carol net = %d, want -333", got)
	}
}

func TestBalancesConserveToZero(t *testing.T) {
	id := mustTab(t, alice, "Conservation Tab")
	mustJoin(t, bob, id)
	mustJoin(t, carol, id)
	mustJoin(t, dave, id)
	all := alice.String() + "," + bob.String() + "," + carol.String() + "," + dave.String()
	if _, err := addExpense(alice, id, 1200, "dinner", all); err != "" {
		t.Fatalf("expense 1: %s", err)
	}
	if _, err := addExpense(bob, id, 400, "drinks", bob.String()+","+carol.String()); err != "" {
		t.Fatalf("expense 2: %s", err)
	}
	if _, err := addExpense(dave, id, 777, "taxi", dave.String()+","+alice.String()); err != "" {
		t.Fatalf("expense 3: %s", err)
	}
	tab := tabs[findTabIndex(id)]
	sum := int64(0)
	for _, m := range tab.Members {
		sum += netBalance(tab, m.Addr)
	}
	if sum != 0 {
		t.Fatalf("nets sum to %d, want 0", sum)
	}
}

func TestSettlementPlanMinimal(t *testing.T) {
	id := mustTab(t, alice, "Plan Tab")
	mustJoin(t, bob, id)
	mustJoin(t, carol, id)
	mustJoin(t, dave, id)
	all := alice.String() + "," + bob.String() + "," + carol.String() + "," + dave.String()
	if _, err := addExpense(alice, id, 1200, "dinner", all); err != "" {
		t.Fatalf("expense 1: %s", err)
	}
	if _, err := addExpense(bob, id, 400, "drinks", bob.String()+","+carol.String()); err != "" {
		t.Fatalf("expense 2: %s", err)
	}
	// Nets: alice +900, bob -100, carol -500, dave -300.
	tab := tabs[findTabIndex(id)]
	if got := netBalance(tab, alice); got != 900 {
		t.Fatalf("alice net = %d, want 900", got)
	}
	plan := planSettlements(tab)
	if len(plan) != 3 {
		t.Fatalf("plan has %d transfers, want 3", len(plan))
	}
	// Applying the plan must zero every balance.
	for _, p := range plan {
		if err := settleRecord(p.From, id, p.To, p.Amount); err != "" {
			t.Fatalf("plan step failed: %s", err)
		}
	}
	tab = tabs[findTabIndex(id)]
	for _, m := range tab.Members {
		if got := netBalance(tab, m.Addr); got != 0 {
			t.Fatalf("after plan, %s net = %d, want 0", m.Addr.String(), got)
		}
	}
}

func TestSettleRecordValidation(t *testing.T) {
	id := mustTab(t, alice, "Validation Tab")
	mustJoin(t, bob, id)
	mustJoin(t, carol, id)
	all := alice.String() + "," + bob.String() + "," + carol.String()
	if _, err := addExpense(alice, id, 900, "dinner", all); err != "" {
		t.Fatalf("expense: %s", err)
	}
	// Nets: alice +600, bob -300, carol -300.
	if err := settleRecord(bob, id, alice, 0); err == "" {
		t.Fatalf("zero amount should fail")
	}
	if err := settleRecord(bob, id, alice, 301); err == "" {
		t.Fatalf("overpay should fail")
	}
	if err := settleRecord(bob, id, carol, 50); err == "" {
		t.Fatalf("settling to a non-creditor should fail")
	}
	if err := settleRecord(alice, id, bob, 50); err == "" {
		t.Fatalf("creditor settling should fail")
	}
	if err := settleRecord(dave, id, alice, 50); err == "" {
		t.Fatalf("non-member settling should fail")
	}
	if err := settleRecord(bob, id, bob, 50); err == "" {
		t.Fatalf("self-settle should fail")
	}
	if err := settleRecord(bob, id, alice, 300); err != "" {
		t.Fatalf("valid settle failed: %s", err)
	}
	tab := tabs[findTabIndex(id)]
	if got := netBalance(tab, bob); got != 0 {
		t.Fatalf("bob net after settle = %d, want 0", got)
	}
	if got := netBalance(tab, alice); got != 300 {
		t.Fatalf("alice net after settle = %d, want 300", got)
	}
}

func TestRemoveExpense(t *testing.T) {
	id := mustTab(t, alice, "Remove Tab")
	mustJoin(t, bob, id)
	parts := alice.String() + "," + bob.String()
	expID, err := addExpense(alice, id, 500, "snacks", parts)
	if err != "" {
		t.Fatalf("expense: %s", err)
	}
	if err := removeExpense(bob, id, expID); err == "" {
		t.Fatalf("non-payer remove should fail")
	}
	if err := removeExpense(alice, id, expID); err != "" {
		t.Fatalf("payer remove failed: %s", err)
	}
	if len(tabs[findTabIndex(id)].Expenses) != 0 {
		t.Fatalf("expense was not removed")
	}
	// After a settlement is recorded, removal is blocked.
	expID, err = addExpense(alice, id, 500, "snacks", parts)
	if err != "" {
		t.Fatalf("expense 2: %s", err)
	}
	if err := settleRecord(bob, id, alice, 250); err != "" {
		t.Fatalf("settle: %s", err)
	}
	if err := removeExpense(alice, id, expID); err == "" {
		t.Fatalf("remove after settlement should fail")
	}
}

func TestCloseTab(t *testing.T) {
	id := mustTab(t, alice, "Close Tab")
	mustJoin(t, bob, id)
	parts := alice.String() + "," + bob.String()
	if _, err := addExpense(alice, id, 500, "snacks", parts); err != "" {
		t.Fatalf("expense: %s", err)
	}
	if err := closeTab(bob, id); err == "" {
		t.Fatalf("non-owner close should fail")
	}
	if err := closeTab(alice, id); err == "" {
		t.Fatalf("close with open balances should fail")
	}
	if err := settleRecord(bob, id, alice, 250); err != "" {
		t.Fatalf("settle: %s", err)
	}
	if err := closeTab(alice, id); err != "" {
		t.Fatalf("close after settle failed: %s", err)
	}
	if err := joinTab(carol, id, ""); err == "" {
		t.Fatalf("join on closed tab should fail")
	}
}

func TestAddExpenseValidation(t *testing.T) {
	id := mustTab(t, alice, "Expense Validation")
	mustJoin(t, bob, id)
	parts := alice.String() + "," + bob.String()
	if _, err := addExpense(alice, id, 0, "free", parts); err == "" {
		t.Fatalf("zero amount should fail")
	}
	if _, err := addExpense(alice, id, 100, "", parts); err == "" {
		t.Fatalf("empty description should fail")
	}
	// Single-participant expense must fail (needs at least 2).
	if _, err := addExpense(alice, id, 100, "x", alice.String()); err == "" {
		t.Fatalf("single-participant expense should fail")
	}
	if _, err := addExpense(bob, id, 100, "x", alice.String()); err == "" {
		t.Fatalf("payer not in participants should fail")
	}
	if _, err := addExpense(alice, id, 100, "x", parts+","+alice.String()); err == "" {
		t.Fatalf("duplicate participant should fail")
	}
	if _, err := addExpense(alice, id, 100, "x", alice.String()+",notanaddress"); err == "" {
		t.Fatalf("bad address should fail")
	}
	if _, err := addExpense(dave, id, 100, "x", parts); err == "" {
		t.Fatalf("non-member expense should fail")
	}
}

func TestRender(t *testing.T) {
	id := mustTab(t, alice, "Render Tab")
	mustJoin(t, bob, id)
	parts := alice.String() + "," + bob.String()
	if _, err := addExpense(alice, id, 500, "ale", parts); err != "" {
		t.Fatalf("expense: %s", err)
	}
	idx := Render("")
	if !strings.Contains(idx, "Render Tab") {
		t.Fatalf("index render missing tab name")
	}
	detail := Render("tab/" + strconv.FormatInt(id, 10))
	if !strings.Contains(detail, "Balances") || !strings.Contains(detail, "Settle up") {
		t.Fatalf("tab render missing sections")
	}
	guide := Render("guide")
	if !strings.Contains(guide, "Settle(") {
		t.Fatalf("guide render missing Settle")
	}
}

func TestSanitizeInline(t *testing.T) {
	if got := sanitizeInline("a|b[c]d`e\nf"); got != "a/b(c)d'e f" {
		t.Fatalf("sanitizeInline = %q, want %q", got, "a/b(c)d'e f")
	}
	if got := sanitizeInline("plain name"); got != "plain name" {
		t.Fatalf("sanitizeInline changed plain text: %q", got)
	}
}
