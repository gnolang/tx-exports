package main

// ─────────────────────────────────────────────────────────────────────────────
// VERSION-SENSITIVE TEST SHIMS — confirmed against test13:
//   - testing.SetOriginCaller(addr)                 // sets runtime.OriginCaller()
//   - testing.SetRealm(testing.NewUserRealm(addr))  // sets PreviousRealm()
//   - testing.NewCodeRealm(path)                    // impersonate a code realm
//   - testutils.TestAddress(name) address           // deterministic test addr
//   - a `func F(cur realm, ...)` is called with the `cross` marker
//
// PANIC ASSERTIONS — two mechanisms, do not mix them up:
//   expectAbort  → revive().  For CROSSING calls, e.g. Tokenize(cross(cur), …).
//                  A panic across a realm boundary is an abort; recover() cannot
//                  catch it.
//   expectPanic  → defer/recover().  For PLAIN same-realm calls, e.g.
//                  ParseUnits("x") or CheckTradeAmount(…). revive() will NOT
//                  catch these.
// ─────────────────────────────────────────────────────────────────────────────

import (
	"strconv"
	"testing"

	"gno.land/p/nt/testutils/v0"

	ledger "gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/demo_v00001/ledger"
)

// testGen is bumped by every resetState(cur) call and folded into mkaddr's
// address so that every test gets addresses no earlier test has ever
// touched. The balances behind these addresses live in the SEPARATE ledger
// realm, whose state persists for the whole `gno test` run — this package
// can't whitebox-reset it the way ledger's own test file resets ledger
// directly.
var testGen int

func mkaddr(name string) address { return testutils.TestAddress(strconv.Itoa(testGen) + "-" + name) }

// units converts whole trading units to base units: units(3) == 3 DEMO.
func units(n uint64) uint64 { return n * UnitScale }

// admin (declared in main.gno) is rebuilt by resetState(cur) on every test.

func setCaller(a address) {
	testing.SetOriginCaller(a)
	testing.SetRealm(testing.NewUserRealm(a))
}

func thisRealm() address {
	return testing.NewCodeRealm("gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/demo_v00001/main").Address()
}

// resetState puts the realm back into a known, isolated state for each test,
// and wires up this test run's ledger instance: Tokenize/Detokenize/Transfer
// cross into the ledger realm, gated on the caller being ledger's registered
// main realm. We impersonate LEDGER's own admin — whatever
// runtime.OriginCaller() its init() captured when this test binary started,
// read back via the plain GetAdmin() query — purely to make that one
// one-time SetMainRealm call.
func resetState(cur realm) {
	testGen++
	admin = mkaddr("admin")
	totalSupply = 0
	burnedTotal = 0
	minTradeSize = UnitScale
	minIncrement = UnitScale

	ledgerAdmin := address(ledger.GetAdmin())
	testing.SetOriginCaller(ledgerAdmin)
	ledger.SetMainRealm(cross(cur), thisRealm())
}

// expectAbort asserts that a CROSSING call panics (surfaces as an abort).
func expectAbort(t *testing.T, name string, fn func()) {
	t.Helper()
	if revive(fn) == nil {
		t.Errorf("%s: expected abort, got none", name)
	}
}

// expectPanic asserts that a PLAIN same-realm call panics.
func expectPanic(t *testing.T, name string, fn func()) {
	t.Helper()
	defer func() {
		if r := recover(); r == nil {
			t.Errorf("%s: expected panic, got none", name)
		}
	}()
	fn()
}

// ─── Product identity ──────────────────────────────────────────────────────────

func TestProductIdentity(t *testing.T) {
	if SKU_() != "DEMO_V00001" {
		t.Errorf("SKU = %s, want DEMO_V00001", SKU_())
	}
	if UnitName_() != "DEMO" {
		t.Errorf("unit name = %s, want DEMO", UnitName_())
	}
	if UnitScale_() != UnitScale {
		t.Errorf("unit scale = %d, want %d", UnitScale_(), UnitScale)
	}
}

// ─── Fixed-point conversion ────────────────────────────────────────────────────

func TestFormatUnits(t *testing.T) {
	assertFormat(t, units(1), "1")
	assertFormat(t, 0, "0")
	assertFormat(t, 2000, "0.2")
	assertFormat(t, 12000, "1.2")
}

func assertFormat(t *testing.T, base uint64, want string) {
	t.Helper()
	if got := FormatUnits(base); got != want {
		t.Errorf("FormatUnits(%d) = %s, want %s", base, got, want)
	}
}

func TestParseUnits(t *testing.T) {
	if got := ParseUnits("1.2"); got != 12000 {
		t.Errorf("ParseUnits(1.2) = %d, want 12000", got)
	}
	if got := FormatUnits(ParseUnits("1.2")); got != "1.2" {
		t.Errorf("round-trip = %s, want 1.2", got)
	}
}

func TestParseUnits_Malformed(t *testing.T) {
	expectPanic(t, "empty", func() { ParseUnits("") })
	expectPanic(t, "letters", func() { ParseUnits("abc") })
	expectPanic(t, "too many decimals", func() { ParseUnits("1.00000") })
}

// ─── Trade rules ───────────────────────────────────────────────────────────────

func TestTradeRules_Defaults(cur realm, t *testing.T) {
	resetState(cur)
	if MinTradeSize() != units(1) {
		t.Errorf("default min trade size = %d, want %d", MinTradeSize(), units(1))
	}
	if !IsValidTradeAmount(units(1)) {
		t.Error("whole units should be valid under the default rules")
	}
	if IsValidTradeAmount(0) {
		t.Error("zero must never be a valid trade amount")
	}
}

func TestSetTradeRules_AdminOnly(cur realm, t *testing.T) {
	resetState(cur)
	setCaller(mkaddr("mallory"))
	expectAbort(t, "non-admin SetTradeRules", func() {
		SetTradeRules(cross(cur), units(1), units(1))
	})

	setCaller(admin)
	SetTradeRules(cross(cur), units(1), units(1))
}

// ─── Tokenize: admin-only, credited straight to the holder ─────────────────────

func TestTokenize_AdminOnly(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")

	setCaller(holder)
	expectAbort(t, "holder self-issue", func() { Tokenize(cross(cur), holder, units(10)) })
	if BalanceOf(holder) != 0 {
		t.Errorf("holder minted without admin: balance = %d", BalanceOf(holder))
	}
}

func TestTokenize_CreditsHolderImmediately(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	setCaller(admin)

	Tokenize(cross(cur), holder, units(100))

	if got := BalanceOf(holder); got != units(100) {
		t.Errorf("holder balance = %d, want %d", got, units(100))
	}
	if got := BalanceOf(admin); got != 0 {
		t.Errorf("admin balance = %d, want 0 (admin must never take custody)", got)
	}
	if got := TokenizedBy(holder); got != units(100) {
		t.Errorf("TokenizedBy(holder) = %d, want %d", got, units(100))
	}
	if got := TotalSupply(); got != units(100) {
		t.Errorf("supply = %d, want %d", got, units(100))
	}
}

func TestTokenize_RespectsTradeRules(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	setCaller(admin)

	expectAbort(t, "fractional mint", func() {
		Tokenize(cross(cur), holder, ParseUnits("1.5"))
	})
	expectAbort(t, "zero mint", func() { Tokenize(cross(cur), holder, 0) })
}

// ─── Detokenize: self-service, own wallet only ─────────────────────────────────

func TestDetokenize_SelfService(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	setCaller(admin)
	Tokenize(cross(cur), holder, units(100))

	setCaller(holder)
	Detokenize(cross(cur), units(30), "certs@example.com")

	if got := BalanceOf(holder); got != units(70) {
		t.Errorf("holder balance = %d, want %d", got, units(70))
	}
	if got := BurnedTotal(); got != units(30) {
		t.Errorf("burned = %d, want %d", got, units(30))
	}
	if got := TotalSupply(); got != units(70) {
		t.Errorf("supply = %d, want %d", got, units(70))
	}
}

func TestDetokenize_CannotTouchAnotherWallet(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	setCaller(admin)
	Tokenize(cross(cur), holder, units(100))

	setCaller(admin)
	expectAbort(t, "admin retires with empty wallet", func() {
		Detokenize(cross(cur), units(10), "certs@example.com")
	})
	if got := BalanceOf(holder); got != units(100) {
		t.Errorf("holder balance changed by another account's retire: %d", got)
	}
}

// ─── Transfer ──────────────────────────────────────────────────────────────────

func TestTransfer_Success(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	alice := mkaddr("alice")
	setCaller(admin)
	Tokenize(cross(cur), holder, units(100))

	setCaller(holder)
	Transfer(cross(cur), alice, units(40))

	if got := BalanceOf(holder); got != units(60) {
		t.Errorf("holder balance = %d, want %d", got, units(60))
	}
	if got := BalanceOf(alice); got != units(40) {
		t.Errorf("alice balance = %d, want %d", got, units(40))
	}
}

func TestTransfer_RespectsTradeRules(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	alice := mkaddr("alice")
	setCaller(admin)
	Tokenize(cross(cur), holder, units(100))

	setCaller(holder)
	expectAbort(t, "self transfer", func() { Transfer(cross(cur), holder, units(1)) })
	expectAbort(t, "over balance", func() { Transfer(cross(cur), alice, units(101)) })
}

// TotalSupply must always equal the sum of every balance.
func TestSupply_AlwaysEqualsSumOfBalances(cur realm, t *testing.T) {
	resetState(cur)
	alice := mkaddr("alice")
	bob := mkaddr("bob")
	setCaller(admin)
	Tokenize(cross(cur), alice, units(100))
	Tokenize(cross(cur), bob, units(60))

	setCaller(alice)
	Transfer(cross(cur), bob, units(40))

	sum := BalanceOf(alice) + BalanceOf(bob)
	if sum != TotalSupply() {
		t.Errorf("sum of balances = %d but TotalSupply = %d", sum, TotalSupply())
	}

	setCaller(bob)
	Detokenize(cross(cur), units(10), "certs@example.com")

	sum = BalanceOf(alice) + BalanceOf(bob)
	if sum != TotalSupply() {
		t.Errorf("after retirement: sum = %d but TotalSupply = %d", sum, TotalSupply())
	}
}

// ─── Dynamic attributes ─────────────────────────────────────────────────────────

func TestDynamicAttr_AdminOnly(cur realm, t *testing.T) {
	resetState(cur)
	setCaller(mkaddr("mallory"))
	expectAbort(t, "non-admin SetDynamicAttr", func() {
		SetDynamicAttr(cross(cur), "status", "suspended")
	})

	setCaller(admin)
	SetDynamicAttr(cross(cur), "status", "suspended")
	if got := GetDynamicAttr("status"); got != "suspended" {
		t.Errorf("status = %q, want suspended", got)
	}
}
