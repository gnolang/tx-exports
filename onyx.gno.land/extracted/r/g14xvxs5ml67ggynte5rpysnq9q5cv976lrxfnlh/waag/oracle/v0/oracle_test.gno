// Tests for the oracle realm.
//
// Harness pattern verified against gnolang/gno tag v1.8.0:
//
//	examples/gno.land/r/demo/profile/profile_test.gno and our own M1 counter
//	tests - testing.SetRealm(testing.NewUserRealm(addr)) + testing.SetHeight(n),
//	then call the crossing function as Fn(cross(cur), ...).
//	gnovm/tests/stdlibs/testing/context_testing.gno - SetRealm / SetHeight /
//	NewUserRealm / NewCodeRealm / SetOriginCaller / SkipHeights.
//
// TWO panic-catching mechanisms, and using the wrong one is a real bug:
//
//   - A call that goes through cross(cur) into a CROSSING function panics
//     ACROSS a realm boundary. Per docs/resources/gno-interrealm-v2.md §9, only
//     the test-mode builtin revive(fn) can catch that; a plain defer/recover
//     lets it abort the whole test binary. -> mustAbort / mustNotAbort.
//     (examples/gno.land/p/nt/grc20/v0/token_test.gno uses revive for exactly
//     this reason; grc20reg uses urequire.AbortsContains, which is revive-based.)
//
//   - A call to a PLAIN function (GetPrice, GetSources, Config, Render) stays
//     inside one realm-context, so its panic is an ordinary Go panic and
//     defer/recover catches it. revive() does NOT - wrapping a plain call in
//     revive let the panic escape and crash the run. -> mustPanic / mustNotPanic.
//     (examples/gno.land/r/nt/grc20reg/v0/grc20reg_test.gno catches the plain
//     validateSlug panic with defer/recover.)
//
// Getting this backwards cost a full failing run on 2026-11-25; the split is
// recorded here so it is not relearned.
package oracle

import (
	"strings"
	"testing"

	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
	"gno.land/p/nt/avl/v0"
)

// The real testnet keys from §5 of the master doc. Using the genuine addresses
// means a test that passes here also passes against the deployed feeders.
var (
	alice      = address("g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh") // admin
	kucoinKey  = address("g1dg7cgrdevgt80c7m5x3vy6k2dywts9hkrptpw0")
	krakenKey  = address("g1lhmlntfyxgtax4hwrtwtts80qga5h3m0e892kh")
	coingeckoK = address("g1kenddl5kj9x67vu65gp2zx6yfyy9fqgq7nutcw")
	stranger   = address("g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5")
)

const asset = "GNOT"

// resetState gives each test a clean slate: realm package vars are shared by
// every test in the package, exactly like on-chain state is shared by every tx.
func resetState() {
	feeds = avl.Tree{}
	cfg = config{
		stalenessBlocks: DefaultStalenessBlocks,
		deviationBps:    DefaultDeviationBps,
		minFreshSources: DefaultMinFreshSources,
		paused:          false,
	}
}

// setup registers the three real sources as admin at the given height.
func setup(cur realm, height int64) {
	resetState()
	testing.SetHeight(height)
	testing.SetRealm(testing.NewUserRealm(alice))
	RegisterSource(cross(cur), "coingecko", asset, coingeckoK)
	RegisterSource(cross(cur), "kraken", asset, krakenKey)
	RegisterSource(cross(cur), "kucoin", asset, kucoinKey)
}

// ---- panic helpers: CROSSING calls (revive) ------------------------------

// mustAbort asserts fn aborted with a panic that crossed a realm boundary, i.e.
// fn calls a crossing function via cross(cur). revive is the only mechanism that
// sees such a panic (interrealm v2 §9).
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

// ---- panic helpers: PLAIN calls (defer/recover) --------------------------

// didPanic runs fn and reports whether it panicked, using ordinary Go recover.
// Correct only for functions that do NOT cross a realm boundary.
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

// submitAs signs a submission as the given key. Crossing: SubmitPrice takes
// cross(cur). An honest, in-guard submission returns normally (no panic), so it
// is safe to call unwrapped; only outlier submissions return normally too (they
// are rejected without panicking), so submitAs itself never needs a wrapper.
func submitAs(cur realm, key address, sourceID string, price feedmath.Price) {
	testing.SetRealm(testing.NewUserRealm(key))
	SubmitPrice(cross(cur), sourceID, asset, price)
}

// ---- registration / authorization ----------------------------------------

func TestRegisterSourceIsAdminOnly(cur realm, t *testing.T) {
	resetState()
	testing.SetHeight(10)

	testing.SetRealm(testing.NewUserRealm(stranger))
	mustAbort(t, "stranger registering a source", func() {
		RegisterSource(cross(cur), "kucoin", asset, kucoinKey)
	})

	if feeds.Size() != 0 {
		t.Fatalf("a rejected registration must not create state, got %d feeds", feeds.Size())
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	mustNotAbort(t, "admin registering a source", func() {
		RegisterSource(cross(cur), "kucoin", asset, kucoinKey)
	})

	f := mustFeedFor(t, asset)
	if f.sources.Size() != 1 {
		t.Fatalf("expected 1 source, got %d", f.sources.Size())
	}
}

// TestRegisterSourceRejectsRealmCall covers the confused-deputy hole: another
// realm calling us must not be able to act as its user. IsUserCall() is false
// for a code realm, so this must abort even when the address matches admin.
func TestRegisterSourceRejectsRealmCall(cur realm, t *testing.T) {
	resetState()
	testing.SetHeight(10)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/impersonator/v0"))

	mustAbort(t, "a code realm calling an admin function", func() {
		RegisterSource(cross(cur), "kucoin", asset, kucoinKey)
	})
}

func TestSubmitPriceRejectsRealmCall(cur realm, t *testing.T) {
	setup(cur, 100)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/evil/impersonator/v0"))

	mustAbort(t, "a code realm submitting a price", func() {
		SubmitPrice(cross(cur), "kucoin", asset, 49050)
	})
}

func TestRegisterSourceValidation(cur realm, t *testing.T) {
	resetState()
	testing.SetHeight(10)
	testing.SetRealm(testing.NewUserRealm(alice))

	mustAbort(t, "empty source id", func() {
		RegisterSource(cross(cur), "", asset, kucoinKey)
	})
	mustAbort(t, "empty asset", func() {
		RegisterSource(cross(cur), "kucoin", "", kucoinKey)
	})
	mustAbort(t, "empty key", func() {
		RegisterSource(cross(cur), "kucoin", asset, address(""))
	})
	mustNotAbort(t, "valid registration", func() {
		RegisterSource(cross(cur), "kucoin", asset, kucoinKey)
	})
	mustAbort(t, "duplicate registration", func() {
		RegisterSource(cross(cur), "kucoin", asset, kucoinKey)
	})
}

func TestSubmitPriceRejectsWrongKey(cur realm, t *testing.T) {
	setup(cur, 100)

	// kucoin's key trying to speak for kraken is the core O2 guarantee.
	mustAbort(t, "kucoin key submitting as kraken", func() {
		submitAs(cur, kucoinKey, "kraken", 49050)
	})
	mustAbort(t, "stranger submitting as kucoin", func() {
		submitAs(cur, stranger, "kucoin", 49050)
	})
	mustAbort(t, "unknown source id", func() {
		submitAs(cur, kucoinKey, "binance", 49050)
	})

	f := mustFeedFor(t, asset)
	if s := f.getSource("kraken"); s != nil && s.hasSubmission {
		t.Fatal("a rejected submission must not be stored")
	}
}

func TestSubmitPriceRejectsBadNumbers(cur realm, t *testing.T) {
	setup(cur, 100)

	mustAbort(t, "zero price", func() { submitAs(cur, kucoinKey, "kucoin", 0) })
	mustAbort(t, "negative price", func() { submitAs(cur, kucoinKey, "kucoin", -1) })
	mustAbort(t, "over-cap price", func() {
		submitAs(cur, kucoinKey, "kucoin", feedmath.MaxPrice+1)
	})

	f := mustFeedFor(t, asset)
	if s := f.getSource("kucoin"); s.hasSubmission {
		t.Fatal("an invalid price must not be stored")
	}
	// An invalid number is a broken feeder, not an outlier: it must not be
	// counted as a deviation rejection either.
	if s := f.getSource("kucoin"); s.rejected != 0 {
		t.Fatalf("invalid prices should not count as rejections, got %d", s.rejected)
	}
}

func TestSubmitPriceUnknownAsset(cur realm, t *testing.T) {
	setup(cur, 100)
	testing.SetRealm(testing.NewUserRealm(kucoinKey))
	mustAbort(t, "submitting for an unregistered asset", func() {
		SubmitPrice(cross(cur), "kucoin", "BTC", 49050)
	})
}

// ---- publishing ----------------------------------------------------------

func TestPublishesMedianOfThree(cur realm, t *testing.T) {
	setup(cur, 100)

	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	submitAs(cur, coingeckoK, "coingecko", 49200)

	price, height := GetPrice(asset)
	if price != 49050 {
		t.Fatalf("published median = %d, want 49050", price)
	}
	if height != 100 {
		t.Fatalf("published at height %d, want 100", height)
	}
}

func TestNoQuorumMeansNoAnswer(cur realm, t *testing.T) {
	setup(cur, 100)

	submitAs(cur, kucoinKey, "kucoin", 48900)

	f := mustFeedFor(t, asset)
	if f.published {
		t.Fatal("one source must not publish a median (quorum is 2)")
	}
	mustPanic(t, "GetPrice with 1 of 3 fresh", func() { GetPrice(asset) })

	// The second fresh source crosses the quorum line.
	submitAs(cur, krakenKey, "kraken", 49050)
	if !f.published {
		t.Fatal("two fresh sources must publish")
	}
	price, _ := GetPrice(asset)
	if price != 48975 { // floor of (48900+49050)/2
		t.Fatalf("median of two = %d, want 48975", price)
	}
}

func TestGetPriceRevertsWhenStale(cur realm, t *testing.T) {
	setup(cur, 1000)

	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	mustNotPanic(t, "fresh read", func() { GetPrice(asset) })

	// Exactly at the window is still fresh (boundary inclusive).
	testing.SetHeight(1000 + DefaultStalenessBlocks)
	mustNotPanic(t, "read at exactly the staleness boundary", func() { GetPrice(asset) })

	// One block past it is not.
	testing.SetHeight(1000 + DefaultStalenessBlocks + 1)
	mustPanic(t, "read one block past the staleness window", func() { GetPrice(asset) })
}

func TestStaleSourceDoesNotCountTowardQuorum(cur realm, t *testing.T) {
	setup(cur, 1000)

	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)

	// kucoin goes quiet; only kraken keeps submitting.
	testing.SetHeight(1400)
	submitAs(cur, krakenKey, "kraken", 49000)

	f := mustFeedFor(t, asset)
	if got := f.countFresh(1400); got != 1 {
		t.Fatalf("fresh sources = %d, want 1 (kucoin is stale)", got)
	}
	mustPanic(t, "GetPrice with only one fresh source", func() { GetPrice(asset) })
}

// TestFutureDatedSubmissionDoesNotCountTowardQuorum is the realm-level guard for
// the bug found in feedmath during M2: a submission dated in the future must not
// be treated as permanently fresh, or a crafted height could keep a dead source
// propping up quorum forever.
func TestFutureDatedSubmissionDoesNotCountTowardQuorum(cur realm, t *testing.T) {
	setup(cur, 1000)

	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)

	f := mustFeedFor(t, asset)
	// Simulate a source whose recorded height is far in the future.
	s := f.getSource("kraken")
	s.height = 99999999

	if got := f.countFresh(1000); got != 1 {
		t.Fatalf("fresh sources = %d, want 1: a future-dated source must not count", got)
	}
	mustPanic(t, "GetPrice backed by a future-dated source", func() { GetPrice(asset) })
}

// ---- pause / admin -------------------------------------------------------

func TestPauseFreezesReadsAndWrites(cur realm, t *testing.T) {
	setup(cur, 100)
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	mustNotPanic(t, "read before pause", func() { GetPrice(asset) })

	testing.SetRealm(testing.NewUserRealm(alice))
	Pause(cross(cur), true)

	mustPanic(t, "GetPrice while paused", func() { GetPrice(asset) })
	mustAbort(t, "SubmitPrice while paused", func() {
		submitAs(cur, kucoinKey, "kucoin", 49000)
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	Pause(cross(cur), false)
	mustNotPanic(t, "read after unpause", func() { GetPrice(asset) })
}

func TestPauseIsAdminOnly(cur realm, t *testing.T) {
	setup(cur, 100)
	testing.SetRealm(testing.NewUserRealm(stranger))
	mustAbort(t, "stranger pausing the feed", func() { Pause(cross(cur), true) })

	if cfg.paused {
		t.Fatal("a rejected pause must not change config")
	}
}

func TestSetConfig(cur realm, t *testing.T) {
	setup(cur, 100)

	testing.SetRealm(testing.NewUserRealm(stranger))
	mustAbort(t, "stranger changing config", func() {
		SetConfig(cross(cur), 10, 500, 1)
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	mustAbort(t, "negative staleness", func() { SetConfig(cross(cur), -1, 500, 1) })
	mustAbort(t, "negative deviation", func() { SetConfig(cross(cur), 10, -1, 1) })
	mustAbort(t, "deviation above 100%", func() { SetConfig(cross(cur), 10, 10001, 1) })
	mustAbort(t, "quorum below 1", func() { SetConfig(cross(cur), 10, 500, 0) })

	mustNotAbort(t, "valid config", func() { SetConfig(cross(cur), 60, 500, 2) })

	s, d, q, p := Config()
	if s != 60 || d != 500 || q != 2 || p {
		t.Fatalf("config = (%d,%d,%d,%v), want (60,500,2,false)", s, d, q, p)
	}
}

// TestTighterConfigTakesEffectImmediately proves the thresholds are read at
// decision time rather than baked in at registration - which is what makes M5's
// burn-in retuning possible without a redeploy.
func TestTighterConfigTakesEffectImmediately(cur realm, t *testing.T) {
	setup(cur, 100)
	submitAs(cur, kucoinKey, "kucoin", 49050)
	submitAs(cur, krakenKey, "kraken", 49050)

	// A 1% (100 bps) guard now rejects what the 10% guard accepted.
	testing.SetRealm(testing.NewUserRealm(alice))
	SetConfig(cross(cur), DefaultStalenessBlocks, 100, DefaultMinFreshSources)

	f := mustFeedFor(t, asset)
	submitAs(cur, coingeckoK, "coingecko", 50000) // ~1.9% off the others

	if s := f.getSource("coingecko"); s.hasSubmission {
		t.Fatal("a price outside the tightened guard must not be stored")
	}
}

func TestRemoveSourceDropsQuorum(cur realm, t *testing.T) {
	setup(cur, 100)
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	mustNotPanic(t, "read with two sources", func() { GetPrice(asset) })

	mustAbort(t, "stranger removing a source", func() {
		testing.SetRealm(testing.NewUserRealm(stranger))
		RemoveSource(cross(cur), "kraken", asset)
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	RemoveSource(cross(cur), "kraken", asset)

	f := mustFeedFor(t, asset)
	if f.sources.Size() != 2 {
		t.Fatalf("sources = %d, want 2 after removal", f.sources.Size())
	}
	if f.countFresh(100) >= cfg.minFreshSources {
		t.Fatal("removing a fresh source should break quorum here")
	}
	mustPanic(t, "GetPrice after losing quorum", func() { GetPrice(asset) })
}

// ---- reads / rendering ---------------------------------------------------

func TestGetSourcesSnapshot(cur realm, t *testing.T) {
	setup(cur, 100)
	submitAs(cur, kucoinKey, "kucoin", 48900)

	out := GetSources(asset)
	for _, want := range []string{"asset=GNOT", "kucoin", "kraken", "coingecko", "FRESH", "NO DATA", "quorum=2"} {
		if !strings.Contains(out, want) {
			t.Errorf("GetSources output missing %q\n---\n%s", want, out)
		}
	}
}

func TestRenderNeverPanics(cur realm, t *testing.T) {
	// Empty state first: a fresh deployment must still render a page.
	resetState()
	testing.SetHeight(5)
	for _, p := range []string{"", "/", "help", "bogus"} {
		mustNotPanic(t, "Render("+p+") on empty state", func() { Render(p) })
	}

	setup(cur, 100)
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	submitAs(cur, coingeckoK, "coingecko", 99200) // rejected as an outlier

	page := Render("")
	for _, want := range []string{
		"GNOT", "published median", "kucoin", "kraken", "coingecko",
		"FRESH", "ANSWERING", "$0.049050", "rejected",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("dashboard missing %q\n---\n%s", want, page)
		}
	}

	if !strings.Contains(Render("help"), "GetPrice") {
		t.Error("help page should document GetPrice")
	}
	if !strings.Contains(Render("bogus"), "unknown path") {
		t.Error("unknown path should say so")
	}
}

func TestRenderShowsPausedState(cur realm, t *testing.T) {
	setup(cur, 100)
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)

	testing.SetRealm(testing.NewUserRealm(alice))
	Pause(cross(cur), true)

	page := Render("")
	if !strings.Contains(page, "PAUSED") {
		t.Errorf("paused dashboard must say so\n---\n%s", page)
	}
	if !strings.Contains(page, "REFUSING") {
		t.Error("paused dashboard must show that GetPrice refuses")
	}
}

func TestFormatHelpers(t *testing.T) {
	cases := []struct {
		in   feedmath.Price
		want string
	}{
		{49050, "$0.049050"},
		{1000000, "$1.000000"},
		{1, "$0.000001"},
		{123456789, "$123.456789"},
		{0, "n/a"},
		{-5, "n/a"},
	}
	for _, c := range cases {
		if got := formatUSD(c.in); got != c.want {
			t.Errorf("formatUSD(%d) = %q, want %q", c.in, got, c.want)
		}
	}

	if got := formatBps(1000); got != "10.00%" {
		t.Errorf("formatBps(1000) = %q, want 10.00%%", got)
	}
	if got := formatBps(25); got != "0.25%" {
		t.Errorf("formatBps(25) = %q, want 0.25%%", got)
	}
	if got := formatAge(-1); got != "n/a" {
		t.Errorf("formatAge(-1) = %q, want n/a", got)
	}
}

// mustFeedFor is the test-side equivalent of mustFeed that reports instead of
// panicking, so a missing feed shows up as a readable test failure.
func mustFeedFor(t *testing.T, a string) *feed {
	t.Helper()
	f := getFeed(a)
	if f == nil {
		t.Fatalf("no feed registered for %q", a)
	}
	return f
}
