package token

// ─────────────────────────────────────────────────────────────────────────────
// VERSION-SENSITIVE TEST SHIMS — confirmed against test13:
//   - testing.SetOriginCaller(addr)                 // sets runtime.OriginCaller()
//   - testing.SetRealm(testing.NewUserRealm(addr))  // sets PreviousRealm()
//   - testing.NewCodeRealm(path)                    // impersonate a code realm
//   - testutils.TestAddress(name) address           // deterministic test addr
//   - a `func F(cur realm, ...)` is called with the `cross` marker
//
// PANIC ASSERTIONS — two mechanisms, do not mix them up:
//   expectAbort  → revive().  For CROSSING calls, e.g. Transfer(cross(cur), …).
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

	ledger "gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/demo_v001/ledger"
)

// testGen is bumped by every resetState(cur) call and folded into mkaddr's
// address so that every test gets addresses no earlier test has ever
// touched. The balances behind these addresses live in the SEPARATE ledger
// realm, whose state persists for the whole `gno test` run and which this
// package can't whitebox-reset the way ledger's own test file resets ledger
// directly.
var testGen int

func mkaddr(name string) address { return testutils.TestAddress(strconv.Itoa(testGen) + "-" + name) }

// units converts whole trading units to base units: units(3) == 3 UNIT.
func units(n uint64) uint64 { return n * UnitScale }

// admin (declared in token.gno) is rebuilt by resetState(cur) on every test.

func setCaller(a address) {
	testing.SetOriginCaller(a)
	testing.SetRealm(testing.NewUserRealm(a))
}

func thisRealm() address {
	return testing.NewCodeRealm("gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/demo_v001/token").Address()
}

// resetState puts the realm back into a known, isolated state for each test,
// and wires up this test run's ledger instance: TokenizeByPlatform/
// TokenizeWithVoucher/Detokenize/Transfer/TransferFrom cross into the ledger
// realm, gated on the caller being ledger's registered main realm. We
// impersonate LEDGER's own admin — whatever runtime.OriginCaller() its
// init() captured when this test binary started, read back via the plain
// GetAdmin() query — purely to make that one one-time SetMainRealm call.
func resetState(cur realm) {
	testGen++
	admin = mkaddr("admin")
	totalSupply = 0
	burnedTotal = 0
	minTradeSize = UnitScale
	minIncrement = UnitScale
	voucherSigner = nil
	voucherValidityMs = DefaultVoucherValidityMs

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
	if SKU_() != "DEMO" {
		t.Errorf("SKU = %s, want DEMO", SKU_())
	}
	if UnitName_() != "UNIT" {
		t.Errorf("unit name = %s, want UNIT", UnitName_())
	}
	if UnitScale_() != UnitScale {
		t.Errorf("unit scale = %d, want %d", UnitScale_(), UnitScale)
	}
	if GetName() != TokenName {
		t.Errorf("GetName() = %s, want %s", GetName(), TokenName)
	}
	if GetSymbol() != SKU {
		t.Errorf("GetSymbol() = %s, want %s", GetSymbol(), SKU)
	}
	if GetDecimals() != uint(UnitDecimals) {
		t.Errorf("GetDecimals() = %d, want %d", GetDecimals(), UnitDecimals)
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

// ─── TokenizeByPlatform: admin-only, credited straight to the holder ──────────

func TestTokenizeByPlatform_AdminOnly(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")

	setCaller(holder)
	expectAbort(t, "holder self-issue", func() { TokenizeByPlatform(cross(cur), holder, units(10)) })
	if BalanceOf(holder) != 0 {
		t.Errorf("holder minted without admin: balance = %d", BalanceOf(holder))
	}
}

func TestTokenizeByPlatform_CreditsHolderImmediately(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	setCaller(admin)

	TokenizeByPlatform(cross(cur), holder, units(100))

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

func TestTokenizeByPlatform_RespectsTradeRules(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	setCaller(admin)

	expectAbort(t, "fractional mint", func() {
		TokenizeByPlatform(cross(cur), holder, ParseUnits("1.5"))
	})
	expectAbort(t, "zero mint", func() { TokenizeByPlatform(cross(cur), holder, 0) })
}

// ─── Detokenize: self-service, own wallet only ─────────────────────────────────

func TestDetokenize_SelfService(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	setCaller(admin)
	TokenizeByPlatform(cross(cur), holder, units(100))

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
	TokenizeByPlatform(cross(cur), holder, units(100))

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
	TokenizeByPlatform(cross(cur), holder, units(100))

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
	TokenizeByPlatform(cross(cur), holder, units(100))

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
	TokenizeByPlatform(cross(cur), alice, units(100))
	TokenizeByPlatform(cross(cur), bob, units(60))

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

// ─── Approve / Allowance / TransferFrom ────────────────────────────────────────

func TestApprove_OverwritesNotAdds(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	spender := mkaddr("spender")
	setCaller(holder)

	Approve(cross(cur), spender, units(10))
	if got := Allowance(holder, spender); got != units(10) {
		t.Errorf("allowance = %d, want %d", got, units(10))
	}

	Approve(cross(cur), spender, units(5))
	if got := Allowance(holder, spender); got != units(5) {
		t.Errorf("allowance after re-approve = %d, want %d (overwrite, not add)", got, units(5))
	}
}

func TestAllowance_UnsetPairReturnsZero(cur realm, t *testing.T) {
	resetState(cur)
	if got := Allowance(mkaddr("nobody"), mkaddr("alsonobody")); got != 0 {
		t.Errorf("allowance for unset pair = %d, want 0", got)
	}
}

func TestTransferFrom_Success(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	spender := mkaddr("spender")
	alice := mkaddr("alice")
	setCaller(admin)
	TokenizeByPlatform(cross(cur), holder, units(100))

	setCaller(holder)
	Approve(cross(cur), spender, units(50))

	setCaller(spender)
	TransferFrom(cross(cur), holder, alice, units(30))

	if got := BalanceOf(holder); got != units(70) {
		t.Errorf("holder balance = %d, want %d", got, units(70))
	}
	if got := BalanceOf(alice); got != units(30) {
		t.Errorf("alice balance = %d, want %d", got, units(30))
	}
	if got := Allowance(holder, spender); got != units(20) {
		t.Errorf("remaining allowance = %d, want %d", got, units(20))
	}
}

func TestTransferFrom_RejectsOverAllowance(cur realm, t *testing.T) {
	resetState(cur)
	holder := mkaddr("holder")
	spender := mkaddr("spender")
	alice := mkaddr("alice")
	setCaller(admin)
	TokenizeByPlatform(cross(cur), holder, units(100))

	setCaller(holder)
	Approve(cross(cur), spender, units(10))

	setCaller(spender)
	expectAbort(t, "over allowance", func() { TransferFrom(cross(cur), holder, alice, units(11)) })
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

// ─── Voucher-authorized tokenization ───────────────────────────────────────────
//
// Fixtures below were generated OFFLINE with Go's real crypto/ed25519 (gno's
// ed25519 package only implements Verify, not Sign) against THIS package's
// own pkgPath (gno.land/r/g172tf235svs0hkckys8kshnam6ncz7pscx9x59f/demo/demo_v001/token)
// and voucherHolder()'s exact address string — see voucherMessage's doc for
// the canonical-JSON byte format these sign over. voucherHolder is a FIXED
// test address (testutils.TestAddress directly, NOT mkaddr's testGen-prefixed
// form) because the signature is bound to this exact address.
//
// testStartMs matches gno test's DefaultTimestamp (1234567890 seconds, fixed
// and deterministic) converted to milliseconds: it's `now` at the start of
// every test.

var voucherPubKey = []byte{0xd2, 0x1b, 0xae, 0x11, 0xac, 0xee, 0xa0, 0xb9, 0x60, 0x26, 0x42, 0x2c, 0xd9, 0x6b, 0xd1, 0x02, 0xb5, 0x18, 0x34, 0xd0, 0x64, 0x7e, 0x6b, 0x5b, 0x10, 0x96, 0x7b, 0x7f, 0x5d, 0xad, 0xd7, 0x8d}

const testStartMs = 1234567890000

func voucherHolder() address { return testutils.TestAddress("voucherholder") }

func TestTokenizeWithVoucher_RejectsWhenSignerNotSet(cur realm, t *testing.T) {
	resetState(cur)
	if HasVoucherSigner() {
		t.Fatal("voucher signer should start disabled")
	}
	// amount=units(5) issuedAt=testStartMs nonce="voucher-1"
	sig := []byte{0xa0, 0x2f, 0x80, 0x33, 0x9a, 0x0c, 0x0c, 0xc6, 0x2c, 0xb2, 0x1c, 0x5e, 0x3e, 0xad, 0xb3, 0x11, 0x5c, 0xc5, 0x85, 0x08, 0x45, 0x86, 0xa4, 0x90, 0x95, 0xb0, 0x72, 0xde, 0x56, 0xc9, 0x1a, 0x96, 0xa8, 0xf8, 0x7f, 0xd8, 0x87, 0xd1, 0x19, 0xd1, 0x4f, 0x13, 0xa4, 0x0c, 0xa3, 0xeb, 0x56, 0x63, 0xad, 0x26, 0x7f, 0xc9, 0x0e, 0x6a, 0x06, 0x50, 0xd8, 0x8d, 0x40, 0x37, 0x4b, 0x7e, 0x20, 0x00}
	expectAbort(t, "voucher before signer set", func() {
		TokenizeWithVoucher(cross(cur), voucherHolder(), units(5), testStartMs, "voucher-1", sig)
	})
}

func TestSetVoucherSigner_AdminOnly(cur realm, t *testing.T) {
	resetState(cur)
	setCaller(mkaddr("mallory"))
	expectAbort(t, "non-admin SetVoucherSigner", func() { SetVoucherSigner(cross(cur), voucherPubKey) })
}

func TestSetVoucherSigner_RejectsBadLength(cur realm, t *testing.T) {
	resetState(cur)
	setCaller(admin)
	expectAbort(t, "wrong-length pubkey", func() { SetVoucherSigner(cross(cur), []byte{0x01, 0x02, 0x03}) })
}

func TestVoucherValidityMs_DefaultsTo60Seconds(cur realm, t *testing.T) {
	resetState(cur)
	if got := VoucherValidityMs(); got != DefaultVoucherValidityMs {
		t.Errorf("default voucher validity = %d, want %d", got, DefaultVoucherValidityMs)
	}
}

func TestTokenizeWithVoucher_Success(cur realm, t *testing.T) {
	resetState(cur)
	setCaller(admin)
	SetVoucherSigner(cross(cur), voucherPubKey)

	holder := voucherHolder()
	// amount=units(5) issuedAt=testStartMs nonce="voucher-1"
	sig := []byte{0xa0, 0x2f, 0x80, 0x33, 0x9a, 0x0c, 0x0c, 0xc6, 0x2c, 0xb2, 0x1c, 0x5e, 0x3e, 0xad, 0xb3, 0x11, 0x5c, 0xc5, 0x85, 0x08, 0x45, 0x86, 0xa4, 0x90, 0x95, 0xb0, 0x72, 0xde, 0x56, 0xc9, 0x1a, 0x96, 0xa8, 0xf8, 0x7f, 0xd8, 0x87, 0xd1, 0x19, 0xd1, 0x4f, 0x13, 0xa4, 0x0c, 0xa3, 0xeb, 0x56, 0x63, 0xad, 0x26, 0x7f, 0xc9, 0x0e, 0x6a, 0x06, 0x50, 0xd8, 0x8d, 0x40, 0x37, 0x4b, 0x7e, 0x20, 0x00}

	TokenizeWithVoucher(cross(cur), holder, units(5), testStartMs, "voucher-1", sig)

	if got := BalanceOf(holder); got != units(5) {
		t.Errorf("holder balance = %d, want %d", got, units(5))
	}
	if !IsVoucherUsed("voucher-1") {
		t.Error("nonce should now be marked used")
	}
}

func TestTokenizeWithVoucher_RejectsReuse(cur realm, t *testing.T) {
	resetState(cur)
	setCaller(admin)
	SetVoucherSigner(cross(cur), voucherPubKey)

	holder := voucherHolder()
	// amount=units(1) issuedAt=testStartMs nonce="voucher-2"
	sig := []byte{0xba, 0x5a, 0xfd, 0xc2, 0x44, 0xc3, 0x05, 0x1d, 0xd7, 0x4c, 0xf6, 0x91, 0xfa, 0xe5, 0x52, 0x0f, 0x26, 0x2c, 0x6b, 0x09, 0xb0, 0xc1, 0x8a, 0x80, 0x64, 0x31, 0xf3, 0x5c, 0x6a, 0x5d, 0x35, 0xda, 0x1c, 0x87, 0x80, 0x48, 0x7a, 0x38, 0xec, 0x98, 0xa1, 0x7f, 0x5e, 0x6d, 0x1d, 0xdd, 0x63, 0xe5, 0xe0, 0x4a, 0x46, 0xd7, 0x7c, 0x69, 0xd3, 0xfa, 0xa1, 0xf8, 0x3e, 0xb8, 0xa9, 0xc4, 0x2b, 0x0e}

	TokenizeWithVoucher(cross(cur), holder, units(1), testStartMs, "voucher-2", sig)
	expectAbort(t, "reused voucher", func() {
		TokenizeWithVoucher(cross(cur), holder, units(1), testStartMs, "voucher-2", sig)
	})
}

func TestTokenizeWithVoucher_RejectsExpired(cur realm, t *testing.T) {
	resetState(cur)
	setCaller(admin)
	SetVoucherSigner(cross(cur), voucherPubKey)

	holder := voucherHolder()
	// amount=units(1) issuedAt=testStartMs-70000 nonce="voucher-expired" — 70s
	// before "now", past the default 60s validity window.
	sig := []byte{0x19, 0xf4, 0xd1, 0x43, 0xb0, 0xb2, 0x50, 0x4e, 0xe6, 0xe8, 0x57, 0x47, 0xfc, 0x02, 0xa2, 0x6e, 0x22, 0x6a, 0x3d, 0xe7, 0x77, 0x3e, 0xee, 0x42, 0xa1, 0xa9, 0xec, 0x65, 0xe1, 0x91, 0x4d, 0x5e, 0xd1, 0x3a, 0xaa, 0x90, 0xdc, 0x81, 0x26, 0x07, 0x5d, 0x5b, 0x4d, 0x9a, 0x77, 0x8a, 0x7f, 0x56, 0x4f, 0x1e, 0x1b, 0x97, 0x7f, 0x3c, 0xb3, 0x43, 0xf1, 0x56, 0x46, 0xff, 0x46, 0x09, 0x4d, 0x0b}

	expectAbort(t, "expired voucher", func() {
		TokenizeWithVoucher(cross(cur), holder, units(1), testStartMs-70000, "voucher-expired", sig)
	})
}

func TestTokenizeWithVoucher_RejectsWrongHolder(cur realm, t *testing.T) {
	resetState(cur)
	setCaller(admin)
	SetVoucherSigner(cross(cur), voucherPubKey)

	// signed for voucherHolder(), amount=units(5) issuedAt=testStartMs
	// nonce="voucher-wrongholder" — submitted here against a DIFFERENT holder.
	sig := []byte{0x62, 0xde, 0x75, 0xe0, 0x05, 0x4b, 0x51, 0xb0, 0xd7, 0x36, 0xd3, 0x0a, 0x7a, 0xa0, 0x8e, 0x80, 0xd4, 0x36, 0xc6, 0xb2, 0x33, 0x5c, 0x22, 0xb5, 0xe7, 0x34, 0xf4, 0x26, 0xaf, 0x32, 0x75, 0x66, 0x27, 0x49, 0x05, 0xf1, 0x7c, 0x27, 0x1a, 0x32, 0xf8, 0x5e, 0x8b, 0xec, 0x93, 0x44, 0xb0, 0x5a, 0x9d, 0x56, 0xc9, 0x2c, 0x4f, 0x13, 0x3d, 0xc6, 0xf6, 0x53, 0x20, 0xe0, 0xdc, 0xe3, 0xf0, 0x0d}

	expectAbort(t, "signature bound to a different holder", func() {
		TokenizeWithVoucher(cross(cur), mkaddr("impostor"), units(5), testStartMs, "voucher-wrongholder", sig)
	})
}
