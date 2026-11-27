// Frozen-feed and render tests for the demo vault - the O14 headline:
// when the oracle refuses to answer, the consumer visibly degrades instead
// of guessing, and mock funds are never held hostage.
//
// Heights continue demo_test.gno's sequence (4000 -> 7000). The helpers
// (setupFeed, submitAs, user, mustAbort...) live in demo_test.gno; same
// package, same test binary.
package demo

import (
	"strings"
	"testing"

	oracle "gno.land/r/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/oracle/v0"
)

func TestFeedFrozenByStaleness(cur realm, t *testing.T) {
	setupFeed(cur, 4000, 45000, 45100)
	testing.SetRealm(testing.NewUserRealm(bob))
	mustNotAbort(t, "depositing while fresh", func() { Deposit(cross(cur), 500000000) })

	testing.SetHeight(4400) // 400 blocks later; the staleness window is 300
	if feedAnswering() {
		t.Fatal("the feed must be frozen 400 blocks after the last submission")
	}

	page := Render("")
	for _, want := range []string{
		"*** FEED FROZEN ***",
		"only 0 of 2 required sources fresh",
		bob.String(),             // the position stays visible...
		"$0.045050",              // ...with its entry price as evidence...
		"| n/a | n/a | FROZEN |", // ...but no guessed valuation.
	} {
		if !strings.Contains(page, want) {
			t.Errorf("frozen dashboard missing %q:\n%s", want, page)
		}
	}

	testing.SetRealm(testing.NewUserRealm(carol))
	mustAbort(t, "depositing while stale", func() { Deposit(cross(cur), 100000000) })

	// The promise: withdrawals never depend on the feed.
	testing.SetRealm(testing.NewUserRealm(bob))
	mustNotAbort(t, "withdrawing while stale", func() { Withdraw(cross(cur)) })
	if positions.Size() != 0 {
		t.Fatalf("withdrawal must succeed while frozen, %d positions left", positions.Size())
	}
}

func TestFeedFrozenByPause(cur realm, t *testing.T) {
	setupFeed(cur, 5000, 45000, 45100)
	testing.SetRealm(testing.NewUserRealm(carol))
	mustNotAbort(t, "carol opening", func() { Deposit(cross(cur), 100000000) })

	testing.SetRealm(testing.NewUserRealm(alice))
	mustNotAbort(t, "admin pausing the oracle", func() { oracle.Pause(cross(cur), true) })

	if feedAnswering() {
		t.Fatal("a paused feed must not answer")
	}
	if got := feedStatusText(); got != "oracle paused" {
		t.Errorf("status = %q, want %q", got, "oracle paused")
	}

	testing.SetRealm(testing.NewUserRealm(bob))
	mustAbort(t, "depositing while paused", func() { Deposit(cross(cur), 100000000) })

	page := Render("")
	if !strings.Contains(page, "*** FEED FROZEN ***") || !strings.Contains(page, "oracle paused") {
		t.Errorf("dashboard must show the pause:\n%s", page)
	}

	// Even paused, the exit stays open.
	testing.SetRealm(testing.NewUserRealm(carol))
	mustNotAbort(t, "withdrawing while paused", func() { Withdraw(cross(cur)) })

	testing.SetRealm(testing.NewUserRealm(alice))
	mustNotAbort(t, "admin unpausing", func() { oracle.Pause(cross(cur), false) })

	// Sources were never stale - the feed answers again in the same block.
	testing.SetRealm(testing.NewUserRealm(bob))
	mustNotAbort(t, "depositing again after unpause", func() { Deposit(cross(cur), 50000000) })
	p := getPosition(bob)
	if p == nil || p.entryPrice != 45050 {
		t.Fatalf("post-unpause entry = %+v, want median 45050", p)
	}
}

func TestRenderDashboardHappy(cur realm, t *testing.T) {
	setupFeed(cur, 6000, 45000, 45100)
	testing.SetRealm(testing.NewUserRealm(bob))
	mustNotAbort(t, "bob depositing 500", func() { Deposit(cross(cur), 500000000) })
	testing.SetRealm(testing.NewUserRealm(carol))
	mustNotAbort(t, "carol depositing 250", func() { Deposit(cross(cur), 250000000) })

	page := ""
	mustNotPanic(t, "rendering the dashboard", func() { page = Render("") })

	// Values cross-checked offline: 500 GNOT * $0.045050 = $22.525 ->
	// valueMicroUSD 22525000 -> "$22.525000"; 250 GNOT -> $11.2625.
	for _, want := range []string{
		"ANSWERING at $0.045050",
		"open positions: 2",
		"total mock 750.000000 GNOT",
		bob.String(),
		carol.String(),
		"500.000000 GNOT",
		"250.000000 GNOT",
		"$22.525000",
		"$11.262500",
		"| 100% | OK |",
		"underwater threshold: 10.00%",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("dashboard missing %q:\n%s", want, page)
		}
	}
	if strings.Contains(page, "FROZEN") || strings.Contains(page, "UNDERWATER") {
		t.Errorf("a healthy dashboard must not show FROZEN/UNDERWATER:\n%s", page)
	}
}

func TestRenderFrozenDegrades(cur realm, t *testing.T) {
	setupFeed(cur, 6400, 45000, 45100)
	testing.SetRealm(testing.NewUserRealm(bob))
	mustNotAbort(t, "opening at 45050", func() { Deposit(cross(cur), 500000000) })

	testing.SetHeight(6800) // stale: 400 > 300
	page := ""
	mustNotPanic(t, "rendering while frozen", func() { page = Render("") })

	for _, want := range []string{
		"*** FEED FROZEN ***",
		"only 0 of 2 required sources fresh",
		bob.String(),
		"$0.045050",
		"| n/a | n/a | FROZEN |",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("frozen dashboard missing %q:\n%s", want, page)
		}
	}
	if strings.Contains(page, "ANSWERING") {
		t.Errorf("a frozen dashboard must not claim ANSWERING:\n%s", page)
	}
}

func TestRenderHelpAndUnknownPath(cur realm, t *testing.T) {
	page := ""
	mustNotPanic(t, "rendering help", func() { page = Render("help") })
	for _, want := range []string{
		"check-then-call",
		"oracle.GetPrice",
		"revive",
		"Withdraw is ALWAYS allowed",
		"UNDERWATER",
		"VaultPositionOpened",
	} {
		if !strings.Contains(page, want) {
			t.Errorf("help missing %q", want)
		}
	}

	unknown := ""
	mustNotPanic(t, "rendering an unknown path", func() { unknown = Render("bogus/path") })
	if !strings.Contains(unknown, "unknown path: bogus/path") {
		t.Errorf("unknown-path render = %q", unknown)
	}
}

// TestCrashUnderwaterAndRecovery is the O14 headline: a price crash drives
// the position visibly UNDERWATER, then the feed (and the page) recover.
//
// The crash ladder respects the oracle's own 10% deviation guard at every
// step - with only one OTHER fresh source, the guard anchors on the last
// published median (oracle guards.gno, deviationReference). Every
// inequality below is the guard's exact integer form diff*1e4 <= 1000*ref,
// cross-checked offline:
//
//	start       median 45050
//	kucoin 41000: 4050*1e4 = 40.50M <= 45.05M -> median {41000,45100} = 43050
//	kraken 41050: 2000*1e4 = 20.00M <= 43.05M -> median {41000,41050} = 41025
//	kucoin 37100: 3925*1e4 = 39.25M <= 41.03M -> median {37100,41050} = 39075
//	kraken 37150: 1925*1e4 = 19.25M <= 39.08M -> median 37125 (pnl -1759 bps)
//
// Recovery climbs back the same way (each step within the guard):
//
//	kucoin 40800: 3675*1e4 = 36.75M <= 37.13M -> median {40800,37150} = 38975
//	kraken 40830: 1855*1e4 = 18.55M <= 38.98M -> median {40800,40830} = 40815
//	kucoin 44800: 3985*1e4 = 39.85M <= 40.82M -> median {44800,40830} = 42815
//	kraken 44850: 2035*1e4 = 20.35M <= 42.82M -> median {44800,44850} = 44825
//	kucoin 45000:  175*1e4 =  1.75M <= 44.83M -> median {45000,44850} = 44925
//	kraken 45100:  175*1e4 =  1.75M <= 44.93M -> median 45050 (baseline)
//
// The recovery matters beyond tidiness: the guard's fallback reference IS
// the last published median, so a crash left behind would make the next
// test's honest 45000 submission a >10% jump and get it REJECTED. Ending
// at the baseline makes the whole suite order-independent.
func TestCrashUnderwaterAndRecovery(cur realm, t *testing.T) {
	setupFeed(cur, 7000, 45000, 45100)
	testing.SetRealm(testing.NewUserRealm(bob))
	mustNotAbort(t, "opening at 45050", func() { Deposit(cross(cur), 500000000) })

	submitAs(cur, kucoinKey, "kucoin", 41000)
	submitAs(cur, krakenKey, "kraken", 41050)
	submitAs(cur, kucoinKey, "kucoin", 37100)
	submitAs(cur, krakenKey, "kraken", 37150)

	price, h := oracle.GetPrice(Asset)
	if price != 37125 || h != 7000 {
		t.Fatalf("crashed median = %d@%d, want 37125@7000", price, h)
	}

	p := getPosition(bob)
	if p == nil {
		t.Fatal("position vanished")
	}
	if got := pnlBps(p.entryPrice, price); got != -1759 { // 7925*1e4/45050
		t.Errorf("pnl = %d bps, want -1759", got)
	}
	if !isUnderwater(p.entryPrice, price) {
		t.Errorf("a -1759 bps move must be underwater at threshold %d", thresholdBps)
	}
	if got := healthPct(p.entryPrice, price); got != 82 { // 3712500/45050
		t.Errorf("health = %d%%, want 82%%", got)
	}

	page := Render("")
	if !strings.Contains(page, "UNDERWATER") {
		t.Errorf("dashboard must flag the position UNDERWATER:\n%s", page)
	}
	// 500 GNOT * $0.037125 = $18.5625 -> valueMicroUSD 18562500 -> "$18.562500".
	if !strings.Contains(page, "$18.562500") {
		t.Errorf("dashboard must show the crashed value:\n%s", page)
	}

	submitAs(cur, kucoinKey, "kucoin", 40800)
	submitAs(cur, krakenKey, "kraken", 40830)
	submitAs(cur, kucoinKey, "kucoin", 44800)
	submitAs(cur, krakenKey, "kraken", 44850)
	submitAs(cur, kucoinKey, "kucoin", 45000)
	submitAs(cur, krakenKey, "kraken", 45100)

	price, _ = oracle.GetPrice(Asset)
	if price != 45050 {
		t.Fatalf("recovered median = %d, want the baseline 45050", price)
	}
	if isUnderwater(p.entryPrice, price) {
		t.Errorf("the position must surface again at the recovered median")
	}
	page = Render("")
	if strings.Contains(page, "UNDERWATER") {
		t.Errorf("dashboard must clear UNDERWATER after recovery:\n%s", page)
	}
	if !strings.Contains(page, "ANSWERING at $0.045050") {
		t.Errorf("dashboard must answer again after recovery:\n%s", page)
	}
}
