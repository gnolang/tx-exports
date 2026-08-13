package ledger

// ─────────────────────────────────────────────────────────────────────────────
// VERSION-SENSITIVE TEST SHIMS — same caveats as this project's other
// realms' tests. See any carbon-credit product's ledger_test.gno for the
// full rundown; this file is a standalone copy, so it repeats the essentials.
// ─────────────────────────────────────────────────────────────────────────────

import (
	"testing"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
)

func setCaller(a address) {
	testing.SetOriginCaller(a)
	testing.SetRealm(testing.NewUserRealm(a))
}

func mkaddr(name string) address { return testutils.TestAddress(name) }

// resetState puts the ledger back into a known, isolated state for each
// test. It builds a FRESH grc20.Token/PrivateLedger pair directly (bypassing
// grc20reg.Register, which only ever runs once for real in init(cur realm) —
// registering the same rlmPath+symbol key twice panics) so every test starts
// with an empty balance/allowance ledger.
func resetState(cur realm) {
	admin = mkaddr("admin")
	mainRealm = address("")
	mainRealmSet = false
	dynamicAttrs = avl.NewTree()
	dynamicAttrs.Set("status", "active")
	dynamicAttrs.Set("unit", "DEMO")
	tokenizedBy = avl.NewTree()
	tok, privateLedger = grc20.NewToken("Demo Token", "DEMO", 4, 0, cur)
}

func expectPanic(t *testing.T, name string, fn func()) {
	t.Helper()
	// fn calls a crossing function (Fn(cross, ...)). A panic raised across a realm
	// boundary becomes an "abort" that plain recover() cannot catch — only the
	// revive() builtin can. revive(fn) runs fn and returns the abort value
	// (non-nil) if it aborted, nil if it did not.
	if revive(fn) == nil {
		t.Errorf("%s: expected panic, got none", name)
	}
}

// mainRealmPath: assertMainRealm is gated on PreviousRealm().Address(), which
// only resolves to a CODE realm across a cross call, so we impersonate via
// NewCodeRealm rather than a user address.
const mainRealmPath = "gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/v01/token"

func registerMainRealm() address {
	a := testing.NewCodeRealm(mainRealmPath).Address()
	mainRealm = a
	mainRealmSet = true
	return a
}

// seed credits `addr` directly (white-box) so tests don't need a real MintTo
// call through the main realm.
func seed(addr address, amount uint64) {
	if err := privateLedger.Mint(addr, int64(amount)); err != nil {
		panic(err)
	}
}

// ─── Wiring gates ────────────────────────────────────────────────────────────

func TestSetAdmin_AdminOnly(cur realm, t *testing.T) {
	resetState(cur)
	setCaller(mkaddr("mallory"))
	expectPanic(t, "non-admin SetAdmin", func() { SetAdmin(cross(cur), mkaddr("x")) })
}

func TestSetMainRealm_AdminOnly(cur realm, t *testing.T) {
	resetState(cur)
	setCaller(mkaddr("mallory"))
	expectPanic(t, "non-admin SetMainRealm", func() { SetMainRealm(cross(cur), mkaddr("x")) })
}

// ─── Every mutation: main-realm-only ─────────────────────────────────────────────

func TestMutatingFns_RejectNonMainRealmCaller(cur realm, t *testing.T) {
	resetState(cur)
	registerMainRealm()
	owner := mkaddr("owner")
	spender := mkaddr("spender")
	seed(owner, 100)

	setCaller(mkaddr("mallory"))
	expectPanic(t, "MintTo non-main-realm", func() { MintTo(cross(cur), owner, 10) })
	expectPanic(t, "BurnFrom non-main-realm", func() { BurnFrom(cross(cur), owner, 10) })
	expectPanic(t, "Transfer non-main-realm", func() { Transfer(cross(cur), owner, spender, 10) })
	expectPanic(t, "Approve non-main-realm", func() { Approve(cross(cur), owner, spender, 10) })
	expectPanic(t, "TransferFrom non-main-realm", func() { TransferFrom(cross(cur), owner, spender, owner, 10) })
	expectPanic(t, "AddTokenized non-main-realm", func() { AddTokenized(cross(cur), owner, 10) })
	expectPanic(t, "SetDynamicAttr non-main-realm", func() { SetDynamicAttr(cross(cur), "k", "v") })
	expectPanic(t, "RemoveDynamicAttr non-main-realm", func() { RemoveDynamicAttr(cross(cur), "status") })
}

func TestMintTo_ViaMainRealm(cur realm, t *testing.T) {
	resetState(cur)
	registerMainRealm()
	owner := mkaddr("owner")

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath)) // become the main realm in THIS frame
	MintTo(cross(cur), owner, 100)
	if got := BalanceOf(owner); got != 100 {
		t.Errorf("balance = %d, want 100", got)
	}
	if got := TotalSupply(); got != 100 {
		t.Errorf("total supply = %d, want 100", got)
	}

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath))
	AddTokenized(cross(cur), owner, 100)
	if got := TokenizedByOf(owner); got != 100 {
		t.Errorf("tokenizedBy = %d, want 100", got)
	}
}

func TestBurnFrom_ViaMainRealm(cur realm, t *testing.T) {
	resetState(cur)
	registerMainRealm()
	owner := mkaddr("owner")
	seed(owner, 100)

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath))
	BurnFrom(cross(cur), owner, 40)
	if got := BalanceOf(owner); got != 60 {
		t.Errorf("balance = %d, want 60", got)
	}

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath))
	expectPanic(t, "burn over balance", func() { BurnFrom(cross(cur), owner, 1000) })
}

func TestTransfer_ViaMainRealm(cur realm, t *testing.T) {
	resetState(cur)
	registerMainRealm()
	owner := mkaddr("owner")
	alice := mkaddr("alice")
	seed(owner, 100)

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath))
	Transfer(cross(cur), owner, alice, 40)
	if got := BalanceOf(owner); got != 60 {
		t.Errorf("owner balance = %d, want 60", got)
	}
	if got := BalanceOf(alice); got != 40 {
		t.Errorf("alice balance = %d, want 40", got)
	}

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath))
	expectPanic(t, "transfer to self", func() { Transfer(cross(cur), owner, owner, 1) })
}

func TestApproveAndTransferFrom_ViaMainRealm(cur realm, t *testing.T) {
	resetState(cur)
	registerMainRealm()
	owner := mkaddr("owner")
	spender := mkaddr("spender")
	alice := mkaddr("alice")
	seed(owner, 100)

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath))
	Approve(cross(cur), owner, spender, 50)
	if got := Allowance(owner, spender); got != 50 {
		t.Errorf("allowance = %d, want 50", got)
	}

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath))
	TransferFrom(cross(cur), owner, spender, alice, 30)
	if got := BalanceOf(alice); got != 30 {
		t.Errorf("alice balance = %d, want 30", got)
	}
	if got := Allowance(owner, spender); got != 20 {
		t.Errorf("remaining allowance = %d, want 20", got)
	}

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath))
	expectPanic(t, "over remaining allowance", func() { TransferFrom(cross(cur), owner, spender, alice, 21) })
}

func TestDynamicAttrs_ViaMainRealm(cur realm, t *testing.T) {
	resetState(cur)
	registerMainRealm()

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath))
	SetDynamicAttr(cross(cur), "description", "A demo token attribute.")
	if got := GetDynamicAttr("description"); got != "A demo token attribute." {
		t.Errorf("description = %q, want the seeded text", got)
	}
	if !HasDynamicAttr("description") {
		t.Error("HasDynamicAttr(description) = false, want true")
	}

	testing.SetRealm(testing.NewCodeRealm(mainRealmPath))
	RemoveDynamicAttr(cross(cur), "description")
	if HasDynamicAttr("description") {
		t.Error("description should be removed")
	}
}
