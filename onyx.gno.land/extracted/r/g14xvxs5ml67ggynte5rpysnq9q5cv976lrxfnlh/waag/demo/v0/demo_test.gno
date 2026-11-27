// Tests for the demo vault realm (ledger O14).
//
// Harness split inherited from the oracle realm's tests, verified against
// gnolang/gno tag v1.8.0:
//
//   - CROSSING calls panic ACROSS a realm boundary; only the test-mode
//     builtin revive() catches them -> mustAbort / mustNotAbort. Crossing
//     here: Deposit, Withdraw, SetThreshold (this realm) and RegisterSource,
//     SubmitPrice, Pause (the imported oracle realm).
//   - PLAIN calls are ordinary Go panics that defer/recover catches ->
//     mustPanic / mustNotPanic. Plain here: Render, feedAnswering and its
//     probes (oracle.Config / GetSources / GetPrice), and the math helpers.
//
// Driving the ORACLE from this package's tests uses the same mechanics the
// oracle's own tests use: testing.SetRealm establishes the caller and
// cross(cur) marks the boundary - the oracle's caller checks read
// cur.Previous(), which is the SetRealm context.
//
// Heights increase across tests (1000 -> 2400 here; freeze_test.gno
// continues 4000 -> 7000). Every test that needs a live feed re-publishes
// one at its own height via setupFeed, and the crash test climbs back to
// the baseline median afterwards, so no test's outcome depends on execution
// order - see TestCrashUnderwaterAndRecovery's comment for why that matters
// (the oracle's deviation guard falls back to the LAST PUBLISHED median).
package demo

import (
	"strings"
	"testing"

	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
	"gno.land/p/nt/avl/v0"
	oracle "gno.land/r/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/oracle/v0"
)

// The real testnet keys from §5 of the master doc: a test that passes here
// also passes against the deployed oracle and feeders. bob/carol are plain
// test addresses in the examples' style (examples/gno.land tests use
// address("addr0") literals).
var (
	alice      = address("g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh") // admin
	kucoinKey  = address("g1dg7cgrdevgt80c7m5x3vy6k2dywts9hkrptpw0")
	krakenKey  = address("g1lhmlntfyxgtax4hwrtwtts80qga5h3m0e892kh")
	coingeckoK = address("g1kenddl5kj9x67vu65gp2zx6yfyy9fqgq7nutcw")

	bob   = address("addr0") // depositor
	carol = address("addr1") // second depositor
)

// sourcesRegistered remembers that the three feeders have been registered.
// Registration is once per test binary: the oracle's state persists across
// tests and cannot be reset from outside (its resetState is unexported).
var sourcesRegistered bool

// resetVault clears THIS realm's state only.
func resetVault() {
	positions = avl.Tree{}
	thresholdBps = DefaultThresholdBps
}

// ensureSources registers the three real sources with the oracle as alice.
func ensureSources(cur realm) {
	if sourcesRegistered {
		return
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	oracle.RegisterSource(cross(cur), "coingecko", Asset, coingeckoK)
	oracle.RegisterSource(cross(cur), "kraken", Asset, krakenKey)
	oracle.RegisterSource(cross(cur), "kucoin", Asset, kucoinKey)
	sourcesRegistered = true
}

// submitAs publishes one price as a feeder key. Crossing, but honest and
// outlier submissions both return normally (the oracle rejects outliers
// without panicking), so no wrapper is needed - same as the oracle tests.
func submitAs(cur realm, key address, sourceID string, price feedmath.Price) {
	testing.SetRealm(testing.NewUserRealm(key))
	oracle.SubmitPrice(cross(cur), sourceID, Asset, price)
}

// setupFeed resets the vault and publishes a fresh median at height h from
// kucoin+kraken (quorum is 2 of 3). Baseline 45000/45100 -> median 45050.
func setupFeed(cur realm, h int64, kucoinPrice, krakenPrice feedmath.Price) {
	resetVault()
	ensureSources(cur)
	testing.SetHeight(h)
	submitAs(cur, kucoinKey, "kucoin", kucoinPrice)
	submitAs(cur, krakenKey, "kraken", krakenPrice)
}

// NOTE ON caller setup (learned the hard way, verified against
// gnovm/adr/migration_guide.md §3 + §11, v1.8.0):
//
// testing.SetRealm does NOT just set a global - it walks to the FIRST
// non-testing frame and mutates THAT frame's `cur` in place. So it only
// takes effect for the realm value of the function it is called directly
// from. A helper like `func user(addr)` (no `cur realm` param) mutates its
// own empty frame and silently no-ops: the test's `cur` keeps whatever the
// previous crossing left behind (here: the last feeder from setupFeed), so
// Deposit would record the FEEDER as depositor instead of bob/carol.
//
// Two correct shapes, both used below:
//   - submitAs/ensureSources take `cur realm` and make the crossing call
//     INSIDE themselves, so SetRealm mutates the very cur they cross with.
//   - the test bodies call testing.SetRealm(testing.NewUserRealm(addr))
//     DIRECTLY (the test fn is the crossing scope), then the mustAbort /
//     mustNotAbort closure captures that mutated cur for Deposit(cross(cur)).
//
// This mirrors the oracle realm's own tests, which SetRealm inline too.

// ---- panic helpers: CROSSING calls (revive) --------------------------------

func mustAbort(t *testing.T, label string, fn func()) {
	t.Helper()
	if r := revive(fn); r == nil {
		t.Errorf("%s: expected an abort, got none", label)
	}
}

func mustNotAbort(t *testing.T, label string, fn func()) {
	t.Helper()
	if r := revive(fn); r != nil {
		t.Errorf("%s: unexpected abort: %v", label, r)
	}
}

// ---- panic helpers: PLAIN calls (defer/recover) ------------------------------

func didPanic(fn func()) (did bool) {
	defer func() {
		if recover() != nil {
			did = true
		}
	}()
	fn()
	return false
}

func mustPanic(t *testing.T, label string, fn func()) {
	t.Helper()
	if !didPanic(fn) {
		t.Errorf("%s: expected a panic, got none", label)
	}
}

func mustNotPanic(t *testing.T, label string, fn func()) {
	t.Helper()
	if didPanic(fn) {
		t.Errorf("%s: unexpected panic", label)
	}
}

// ---- authorization ----------------------------------------------------------

func TestDepositRejectsRealmCall(cur realm, t *testing.T) {
	testing.SetHeight(1000)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/impersonator/v0"))
	mustAbort(t, "a code realm opening a position for its user", func() {
		Deposit(cross(cur), 100000000)
	})
}

func TestWithdrawRejectsRealmCall(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/impersonator/v0"))
	mustAbort(t, "a code realm withdrawing", func() {
		Withdraw(cross(cur))
	})
}

func TestSetThresholdRejectsRealmCall(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/impersonator/v0"))
	mustAbort(t, "a code realm tuning the threshold", func() {
		SetThreshold(cross(cur), 500)
	})
}

func TestSetThresholdIsAdminOnly(cur realm, t *testing.T) {
	resetVault()
	testing.SetRealm(testing.NewUserRealm(bob))
	mustAbort(t, "a non-admin tuning the threshold", func() {
		SetThreshold(cross(cur), 500)
	})
	if thresholdBps != DefaultThresholdBps {
		t.Fatalf("a rejected SetThreshold must not change state, got %d", thresholdBps)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	mustNotAbort(t, "admin tuning the threshold", func() {
		SetThreshold(cross(cur), 1500)
	})
	if thresholdBps != 1500 {
		t.Fatalf("threshold = %d, want 1500", thresholdBps)
	}
	mustAbort(t, "threshold above the 10000 bps cap", func() {
		SetThreshold(cross(cur), 10001)
	})
	mustAbort(t, "negative threshold", func() {
		SetThreshold(cross(cur), -1)
	})
	if thresholdBps != 1500 {
		t.Fatalf("rejected retunes must not change state, got %d", thresholdBps)
	}
	resetVault()
}

func TestWithdrawWithoutPosition(cur realm, t *testing.T) {
	resetVault()
	testing.SetRealm(testing.NewUserRealm(bob))
	mustAbort(t, "withdrawing with no open position", func() {
		Withdraw(cross(cur))
	})
}

// ---- deposit validation & the happy path ------------------------------------

func TestDepositValidation(cur realm, t *testing.T) {
	setupFeed(cur, 2000, 45000, 45100)
	testing.SetRealm(testing.NewUserRealm(bob))
	mustAbort(t, "zero amount", func() { Deposit(cross(cur), 0) })
	mustAbort(t, "negative amount", func() { Deposit(cross(cur), -5) })
	mustAbort(t, "amount above the cap", func() { Deposit(cross(cur), MaxPositionUGNOT+1) })
	if positions.Size() != 0 {
		t.Fatalf("rejected deposits must not create positions, got %d", positions.Size())
	}
}

func TestDepositRecordsEntryFromOracle(cur realm, t *testing.T) {
	setupFeed(cur, 2100, 45000, 45100)
	testing.SetRealm(testing.NewUserRealm(bob))
	mustNotAbort(t, "depositing with a live feed", func() {
		Deposit(cross(cur), 500000000) // 500 mock GNOT
	})

	p := getPosition(bob)
	if p == nil {
		t.Fatal("position not stored")
	}
	if p.depositor != bob {
		t.Errorf("depositor = %v, want bob", p.depositor)
	}
	if p.amountUGNOT != 500000000 {
		t.Errorf("amount = %d, want 500000000", p.amountUGNOT)
	}
	// The entry must be the PUBLISHED MEDIAN (45050), not either raw quote.
	if p.entryPrice != 45050 {
		t.Errorf("entry price = %d, want the published median 45050", p.entryPrice)
	}
	if p.entryHeight != 2100 {
		t.Errorf("entry height = %d, want 2100", p.entryHeight)
	}
	if positions.Size() != 1 {
		t.Errorf("expected 1 position, got %d", positions.Size())
	}
}

func TestDepositOnePositionPerDepositor(cur realm, t *testing.T) {
	setupFeed(cur, 2200, 45000, 45100)
	testing.SetRealm(testing.NewUserRealm(bob))
	mustNotAbort(t, "bob's first deposit", func() { Deposit(cross(cur), 100000000) })
	mustAbort(t, "bob's second deposit while one is open", func() { Deposit(cross(cur), 100000000) })

	testing.SetRealm(testing.NewUserRealm(carol))
	mustNotAbort(t, "carol depositing while bob has a position", func() {
		Deposit(cross(cur), 250000000)
	})
	if positions.Size() != 2 {
		t.Fatalf("expected 2 positions, got %d", positions.Size())
	}
}

func TestWithdrawClosesPosition(cur realm, t *testing.T) {
	setupFeed(cur, 2300, 45000, 45100)
	testing.SetRealm(testing.NewUserRealm(bob))
	mustNotAbort(t, "opening", func() { Deposit(cross(cur), 100000000) })
	mustNotAbort(t, "withdrawing with a live feed", func() { Withdraw(cross(cur)) })
	if positions.Size() != 0 {
		t.Fatalf("position not removed, %d left", positions.Size())
	}
	mustAbort(t, "withdrawing twice", func() { Withdraw(cross(cur)) })
}

// ---- threshold retune (the underwater flag is admin-tunable) -----------------

func TestThresholdRetunesUnderwaterFlag(cur realm, t *testing.T) {
	setupFeed(cur, 2400, 45000, 45100)
	testing.SetRealm(testing.NewUserRealm(bob))
	mustNotAbort(t, "opening at 45050", func() { Deposit(cross(cur), 500000000) })

	// One-step dip: kucoin 41000 vs reference 45050 (the published median -
	// only one OTHER fresh source exists, so the guard's fallback applies):
	// 4050*1e4 = 40.5M <= 45.05M, accepted. The fresh pair {41000, 45100}
	// then recomputes to median 41000+(4100/2) = 43050.
	submitAs(cur, kucoinKey, "kucoin", 41000)
	price, _ := oracle.GetPrice(Asset)
	if price != 43050 {
		t.Fatalf("dipped median = %d, want 43050", price)
	}

	p := getPosition(bob)
	if got := pnlBps(p.entryPrice, price); got != -443 { // 2000*1e4/45050 = 443.9
		t.Errorf("pnl = %d bps, want -443", got)
	}
	if isUnderwater(p.entryPrice, price) {
		t.Errorf("a 4.4%% dip must not be underwater at the default 10%% threshold")
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	mustNotAbort(t, "tightening the threshold to 400 bps", func() {
		SetThreshold(cross(cur), 400)
	})
	if !isUnderwater(p.entryPrice, price) {
		t.Errorf("the same dip must be underwater at a 400 bps threshold")
	}
	page := Render("")
	if !strings.Contains(page, "UNDERWATER") {
		t.Errorf("dashboard must flag the position UNDERWATER:\n%s", page)
	}

	mustNotAbort(t, "restoring the default threshold", func() {
		SetThreshold(cross(cur), DefaultThresholdBps)
	})
	if isUnderwater(p.entryPrice, price) {
		t.Errorf("the restored threshold must clear the underwater flag")
	}
	page = Render("")
	if strings.Contains(page, "UNDERWATER") {
		t.Errorf("the flag must clear on the page too:\n%s", page)
	}
}
