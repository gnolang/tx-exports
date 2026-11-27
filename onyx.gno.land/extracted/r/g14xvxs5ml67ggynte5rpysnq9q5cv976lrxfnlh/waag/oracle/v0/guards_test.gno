// Tests for the oracle's guards: the deviation rule (O5), the quorum/staleness
// rules (O6), and - most importantly - whether submission ORDER can change what
// gets published. §9.2 of the master doc names that as a required property.
package oracle

import (
	"testing"

	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
)

// ---- the deviation guard in steady state ---------------------------------

func TestDeviationGuardRejectsOutlier(cur realm, t *testing.T) {
	setup(cur, 100)
	f := mustFeedFor(t, asset)

	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)

	// ~102% above the other two: far outside the 10% guard.
	submitAs(cur, coingeckoK, "coingecko", 99200)

	s := f.getSource("coingecko")
	if s.hasSubmission {
		t.Fatal("an outlier must not be stored")
	}
	if s.rejected != 1 {
		t.Errorf("rejection count = %d, want 1", s.rejected)
	}
	if s.lastRejectBps < 10000 {
		t.Errorf("last rejection should read as >100%% off, got %d bps", s.lastRejectBps)
	}
}

// TestRejectedPriceNeverEntersMedian is the invariant §9.2 calls out by name:
// a rejected price must not influence the published number at all.
func TestRejectedPriceNeverEntersMedian(cur realm, t *testing.T) {
	setup(cur, 100)

	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	before, _ := GetPrice(asset)

	submitAs(cur, coingeckoK, "coingecko", 99200) // rejected

	after, _ := GetPrice(asset)
	if before != after {
		t.Fatalf("a rejected submission moved the median: %d -> %d", before, after)
	}
	if after != 48975 {
		t.Fatalf("median = %d, want 48975 (floor of the two honest prices)", after)
	}
}

func TestDeviationGuardAcceptsHonestSpread(cur realm, t *testing.T) {
	setup(cur, 100)

	// Real GNOT quotes from the three sources sit within a few tenths of a
	// percent of each other; the 10% guard must never fire on honest noise.
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	submitAs(cur, coingeckoK, "coingecko", 49200)

	f := mustFeedFor(t, asset)
	for _, id := range []string{"kucoin", "kraken", "coingecko"} {
		if s := f.getSource(id); s.rejected != 0 || !s.hasSubmission {
			t.Errorf("%s: honest spread was rejected (rejected=%d stored=%v)",
				id, s.rejected, s.hasSubmission)
		}
	}
	if price, _ := GetPrice(asset); price != 49050 {
		t.Fatalf("median = %d, want 49050", price)
	}
}

// TestDeviationGuardBoundaryAtExactlyTenPercent pins the documented edge: a
// deviation of exactly the threshold is accepted, one unit beyond is not.
func TestDeviationGuardBoundaryAtExactlyTenPercent(cur realm, t *testing.T) {
	setup(cur, 100)
	f := mustFeedFor(t, asset)

	// Two anchors at 50000, so the reference the third source is judged
	// against is exactly 50000. Ten percent of that is 5000 units.
	submitAs(cur, kucoinKey, "kucoin", 50000)
	submitAs(cur, krakenKey, "kraken", 50000)

	submitAs(cur, coingeckoK, "coingecko", 55000) // exactly +10%
	if s := f.getSource("coingecko"); !s.hasSubmission || s.rejected != 0 {
		t.Errorf("exactly at the threshold must be ACCEPTED (stored=%v rejected=%d)",
			s.hasSubmission, s.rejected)
	}

	// Reset the same source and try one unit further out.
	submitAs(cur, coingeckoK, "coingecko", 55001) // +10.0002%
	if s := f.getSource("coingecko"); s.rejected != 1 {
		t.Errorf("one unit past the threshold must be REJECTED (rejected=%d)", s.rejected)
	}
	if s := f.getSource("coingecko"); s.price != 55000 {
		t.Errorf("the rejected price must not overwrite the stored one, got %d", s.price)
	}
}

// TestDeviationReferenceExcludesSubmitter proves a source cannot anchor the
// reference to its own previous (possibly wrong) number: the guard judges a
// candidate against the OTHERS only.
func TestDeviationReferenceExcludesSubmitter(cur realm, t *testing.T) {
	setup(cur, 100)
	f := mustFeedFor(t, asset)

	submitAs(cur, kucoinKey, "kucoin", 49050)
	submitAs(cur, krakenKey, "kraken", 49050)
	submitAs(cur, coingeckoK, "coingecko", 49050)

	// kucoin now doubles its quote. The reference must come from kraken and
	// coingecko (49050), NOT include kucoin's own 49050 or its new number.
	submitAs(cur, kucoinKey, "kucoin", 98100)

	if s := f.getSource("kucoin"); s.rejected != 1 {
		t.Errorf("kucoin's doubled quote should be rejected, rejections = %d", s.rejected)
	}
	if s := f.getSource("kucoin"); s.price != 49050 {
		t.Errorf("kucoin's stored price should still be 49050, got %d", s.price)
	}
	if price, _ := GetPrice(asset); price != 49050 {
		t.Errorf("published median moved to %d, want 49050", price)
	}
	_ = f
}

func TestDeviationGuardStandsAsideAtBootstrap(cur realm, t *testing.T) {
	setup(cur, 100)
	f := mustFeedFor(t, asset)

	// The very first submission has nothing to be judged against. Blocking it
	// would make the feed impossible to start, so the guard stands aside.
	submitAs(cur, kucoinKey, "kucoin", 48900)
	if s := f.getSource("kucoin"); !s.hasSubmission {
		t.Fatal("the first submission must be accepted")
	}
	if f.published {
		t.Fatal("one source is below quorum, nothing should be published yet")
	}

	// The second still has only one other source and nothing published, so the
	// guard stands aside again - but now quorum is met and a median publishes.
	submitAs(cur, krakenKey, "kraken", 49050)
	if s := f.getSource("kraken"); !s.hasSubmission {
		t.Fatal("the second submission must be accepted at bootstrap")
	}
	if !f.published {
		t.Fatal("two fresh sources must publish")
	}
}

// ---- ordering ------------------------------------------------------------

// TestOrderIndependence_HonestPrices is the §9.2 property test: no matter what
// order the three sources submit in, the published median must be the same.
// Submission order on a live chain is arbitrary, so an order-dependent result
// would be a consensus-level bug.
func TestOrderIndependence_HonestPrices(cur realm, t *testing.T) {
	type sub struct {
		key   address
		id    string
		price feedmath.Price
	}
	subs := []sub{
		{kucoinKey, "kucoin", 48900},
		{krakenKey, "kraken", 49050},
		{coingeckoK, "coingecko", 49200},
	}
	orders := [][3]int{
		{0, 1, 2}, {0, 2, 1}, {1, 0, 2},
		{1, 2, 0}, {2, 0, 1}, {2, 1, 0},
	}

	var want feedmath.Price = -1
	for _, o := range orders {
		setup(cur, 100)
		for _, i := range o {
			submitAs(cur, subs[i].key, subs[i].id, subs[i].price)
		}
		got, _ := GetPrice(asset)
		if want == -1 {
			want = got
			continue
		}
		if got != want {
			t.Errorf("order %v published %d, but another order published %d", o, got, want)
		}
	}
	if want != 49050 {
		t.Errorf("published median = %d, want 49050", want)
	}
}

// TestBootstrapPoisoningIsDefeated is the regression test for ledger O19
// (owner-approved 2026-11-25). It replays the exact attack the weakness
// described - one compromised key striking during the bootstrap window, when
// nothing is published and the deviation guard has no reference - and asserts
// the consistent-subset fix defeats it at every step:
//
//  1. The attacker submits a wild price first. It is ACCEPTED (a lone first
//     submission has nothing to be judged against - unavoidable), but nothing
//     publishes: one fresh source is below quorum.
//  2. An honest source submits. The wild+honest pair disagrees by more than
//     the threshold, so the consistency cull drops BOTH (each is >10% from
//     their own midpoint) -> no quorum among survivors -> the feed STAYS
//     FROZEN. Before the fix, the midpoint of {wild, honest} published here
//     and GetPrice served it.
//  3. The second honest source submits. The provisional median now sits in the
//     honest cluster; the attacker is the sole cull; the honest pair meets
//     quorum -> the HONEST median publishes and GetPrice serves it. The guard
//     let this submission in because the wild+honest pair culls to nothing,
//     leaving no reference - standing aside, not anchoring on poison.
//  4. The attacker resubmits: judged against the consistent honest reference
//     -> REJECTED by the deviation guard. The feed has self-healed.
//
// Note what step 1 leaves behind: the attacker's price stays STORED (it was
// legitimately accepted when no reference existed) and shows as an outlier on
// the dashboard, but it is permanently culled from the median for as long as
// it disagrees with the honest cluster. Erasing it would hide evidence.
func TestBootstrapPoisoningIsDefeated(cur realm, t *testing.T) {
	setup(cur, 100)
	f := mustFeedFor(t, asset)

	// 1. compromised coingecko strikes first with ~2x the real price.
	submitAs(cur, coingeckoK, "coingecko", 99200)
	if s := f.getSource("coingecko"); !s.hasSubmission {
		t.Fatal("the first-ever submission cannot be judged and must be accepted")
	}
	if f.published {
		t.Fatal("a lone source is below quorum; nothing may publish")
	}

	// 2. honest kucoin. The disagreeing pair culls to nothing -> frozen.
	submitAs(cur, kucoinKey, "kucoin", 48900)
	if f.published {
		t.Fatalf("a wild+honest pair must not publish (got median %d); the feed must freeze", f.median)
	}
	mustPanic(t, "GetPrice during the frozen bootstrap", func() { GetPrice(asset) })

	// 3. honest kraken -> the honest cluster wins and publishes.
	submitAs(cur, krakenKey, "kraken", 49050)
	if !f.published {
		t.Fatal("two consistent sources must publish once the attacker is culled")
	}
	price, _ := GetPrice(asset)
	if price != 48975 {
		t.Fatalf("published %d, want 48975 (median of the honest pair)", price)
	}
	if f.included != 2 {
		t.Fatalf("median built from %d sources, want 2 (the attacker must be culled)", f.included)
	}

	// 4. the attacker retries and is now rejected by the guard.
	submitAs(cur, coingeckoK, "coingecko", 99200)
	s := f.getSource("coingecko")
	if s.rejected != 1 {
		t.Errorf("attacker rejections = %d, want 1", s.rejected)
	}
	if s.price != 99200 {
		t.Errorf("the rejected retry must not change the stored price, got %d", s.price)
	}
	if price2, _ := GetPrice(asset); price2 != 48975 {
		t.Errorf("median moved to %d after the attack was repelled, want 48975", price2)
	}
}

// TestDisagreeingPairFreezesNotMidpoint pins the deliberate behaviour change
// O19 made for exactly two fresh sources.
//
// If they are more than 2x the threshold apart, each sits >10% from their own
// midpoint, the cull drops both, and the feed publishes NOTHING instead of a
// coin-flip midpoint (O12: freeze rather than serve a rotten number). If they
// are within 2x the threshold, both survive the cull and the midpoint still
// publishes - the honest two-source bootstrap is unchanged.
func TestDisagreeingPairFreezesNotMidpoint(cur realm, t *testing.T) {
	setup(cur, 100)
	f := mustFeedFor(t, asset)

	// 48900 vs 60000 is ~22.7% apart: midpoint 54450, each ~10.2% from it.
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 60000)

	if f.published {
		t.Fatalf("a wildly disagreeing pair must not publish their midpoint (got %d)", f.median)
	}
	mustPanic(t, "GetPrice on a disagreeing pair", func() { GetPrice(asset) })

	// A third source siding with one cluster resolves the disagreement.
	submitAs(cur, coingeckoK, "coingecko", 48950)
	if !f.published {
		t.Fatal("two consistent sources out of three must publish")
	}
	price, _ := GetPrice(asset)
	if price != 48925 {
		t.Fatalf("published %d, want 48925 (median of the consistent pair)", price)
	}
	if f.included != 2 {
		t.Fatalf("median built from %d sources, want 2 (kraken culled)", f.included)
	}
}

// TestNearPairStillPublishesMidpoint is the OTHER side of the O19 boundary:
// two sources within 2x the threshold of each other agree on a midpoint (each
// is within the threshold of it), so the honest two-source bootstrap publishes
// exactly as it did before the fix. 48900 vs 55000 is ~12.5% apart: midpoint
// 51950, each ~5.9% from it -> both survive -> midpoint publishes.
func TestNearPairStillPublishesMidpoint(cur realm, t *testing.T) {
	setup(cur, 100)

	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 55000)

	price, _ := GetPrice(asset)
	if price != 51950 {
		t.Fatalf("published %d, want 51950 (midpoint of a near-enough pair)", price)
	}
}

// ---- quorum / staleness interaction --------------------------------------

func TestQuorumIsRecomputedNotCached(cur realm, t *testing.T) {
	setup(cur, 1000)
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	submitAs(cur, coingeckoK, "coingecko", 49200)
	mustNotPanic(t, "read with three fresh", func() { GetPrice(asset) })

	// Everyone goes quiet. Nothing was erased, but the answer must stop.
	testing.SetHeight(1000 + DefaultStalenessBlocks + 1)
	mustPanic(t, "read after every source went stale", func() { GetPrice(asset) })

	// Two sources come back and the feed answers again without any admin action.
	submitAs(cur, kucoinKey, "kucoin", 48950)
	submitAs(cur, krakenKey, "kraken", 49050)
	mustNotPanic(t, "read after quorum recovered", func() { GetPrice(asset) })

	price, _ := GetPrice(asset)
	if price != 49000 {
		t.Fatalf("median after recovery = %d, want 49000", price)
	}
}

func TestRaisingQuorumAboveSourcesFreezesFeed(cur realm, t *testing.T) {
	setup(cur, 100)
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	mustNotPanic(t, "read at quorum 2", func() { GetPrice(asset) })

	testing.SetRealm(testing.NewUserRealm(alice))
	SetConfig(cross(cur), DefaultStalenessBlocks, DefaultDeviationBps, 4)

	// Quorum 4 with 3 registered sources can never be met: the feed must refuse
	// rather than answer. Fail-safe, not fail-open.
	mustPanic(t, "read with quorum above the source count", func() { GetPrice(asset) })
}
