// M3 scenario tests: multi-act stories played out by moving the chain clock
// with testing.SkipHeights (signature verified against
// gnovm/tests/stdlibs/testing/context_testing.gno: advances Height by count
// and Time by 5s per block; usage precedent:
// examples/quarantined/gno.land/r/tests/vm/skipheight/skiptime_test.gno).
//
// These are the §14 M3 "source death" and "poisoned source" scenarios. The
// unit tests prove individual rules; these prove the rules compose into sane
// behaviour over time, which is what an operator actually experiences.
package oracle

import (
	"testing"
)

// TestScenario_SourceDeath plays a full feeder-failure story:
//
//	Act 1  all three sources healthy -> median 49050 published, ANSWERING.
//	Act 2  kucoin's feeder dies (stops submitting). After its prices go stale,
//	       kraken+coingecko keep the feed alive: quorum degrades 3->2, median
//	       49125, still ANSWERING. Graceful degradation, not an outage.
//	Act 3  kraken dies too. One fresh source is below quorum -> GetPrice
//	       REFUSES. The last median is NOT erased (f.published stays true,
//	       f.median stays 49125) - the dashboard keeps the evidence of what
//	       the feed last believed while refusing to serve it as current.
//	Act 4  everyone comes back -> full quorum, median 49050, ANSWERING.
//
// Staleness boundary is exact (feedmath: age == window is fresh, window+1 is
// stale, cross-checked in Python): skips of 301 blocks against the 300-block
// default window.
func TestScenario_SourceDeath(cur realm, t *testing.T) {
	setup(cur, 100)
	f := mustFeedFor(t, asset)

	// Act 1: healthy.
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	submitAs(cur, coingeckoK, "coingecko", 49200)
	if p, _ := GetPrice(asset); p != 49050 {
		t.Fatalf("act 1: published %d, want 49050", p)
	}
	if f.included != 3 {
		t.Fatalf("act 1: included %d, want 3", f.included)
	}

	// Act 2: kucoin dies at h100; at h401 its age is 301 > 300 -> stale.
	testing.SkipHeights(301)
	submitAs(cur, krakenKey, "kraken", 49050)
	submitAs(cur, coingeckoK, "coingecko", 49200)
	if p, _ := GetPrice(asset); p != 49125 {
		t.Fatalf("act 2: published %d, want 49125 (median of the surviving pair)", p)
	}
	if f.included != 2 {
		t.Fatalf("act 2: included %d, want 2 (kucoin must be culled by staleness)", f.included)
	}

	// Act 3: kraken dies too. Only coingecko keeps submitting.
	testing.SkipHeights(301) // h702: kucoin+kraken ages 602/301 -> stale
	submitAs(cur, coingeckoK, "coingecko", 49200)
	mustPanic(t, "act 3: GetPrice below quorum", func() { GetPrice(asset) })
	if !f.published || f.median != 49125 {
		t.Fatalf("act 3: last median erased (published=%v median=%d); evidence must survive", f.published, f.median)
	}

	// Act 4: full recovery, all three fresh again at h702.
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	p, h := GetPrice(asset)
	if p != 49050 || h != 702 {
		t.Fatalf("act 4: got (%d, %d), want (49050, 702)", p, h)
	}
	if f.included != 3 {
		t.Fatalf("act 4: included %d, want 3", f.included)
	}
}

// TestScenario_PoisonedSourceDuringOutage is the OTHER half of O19: the
// bootstrap window can never REOPEN once something has been published.
//
//	Act 1  honest cluster publishes 49050.
//	Act 2  total outage: all sources go stale, feed refuses (correct).
//	Act 3  a compromised coingecko spams 99200 through the outage. Every
//	       submission is REJECTED by the deviation guard, whose reference is
//	       the last published median (deviationReference step 2) - the wild
//	       price is never stored, never published, and the rejection counter
//	       keeps public evidence. Pre-O19 reasoning said "no reference during
//	       an outage"; that is only true before the FIRST publication.
//	Act 4  honest sources return; they are judged against the last published
//	       median, accepted, and the feed republishes the honest number while
//	       the attacker's stale entry sits visibly in the table.
//	Act 5  one more attack attempt -> still rejected, now against the fresh
//	       consistent reference. Median never moved to poison at any point.
func TestScenario_PoisonedSourceDuringOutage(cur realm, t *testing.T) {
	setup(cur, 100)
	f := mustFeedFor(t, asset)
	coingecko := f.getSource("coingecko")

	// Act 1: honest publication.
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	submitAs(cur, coingeckoK, "coingecko", 49200)
	if p, _ := GetPrice(asset); p != 49050 {
		t.Fatalf("act 1: published %d, want 49050", p)
	}

	// Act 2: outage - everyone goes stale.
	testing.SkipHeights(301) // h401
	mustPanic(t, "act 2: GetPrice during a total outage", func() { GetPrice(asset) })

	// Act 3: attacker spams through the outage, time passing between shots.
	for i := int64(1); i <= 3; i++ {
		submitAs(cur, coingeckoK, "coingecko", 99200)
		if coingecko.rejected != i {
			t.Fatalf("act 3 shot %d: rejected=%d, want %d", i, coingecko.rejected, i)
		}
		if coingecko.price != 49200 {
			t.Fatalf("act 3 shot %d: rejected price was STORED (%d)", i, coingecko.price)
		}
		if f.median != 49050 {
			t.Fatalf("act 3 shot %d: median moved to %d under attack", i, f.median)
		}
		mustPanic(t, "act 3: GetPrice must keep refusing while only poison is fresh-lacking",
			func() { GetPrice(asset) })
		testing.SkipHeights(50)
	}

	// Act 4: honest majority returns (h551 after the skips above).
	submitAs(cur, kucoinKey, "kucoin", 48900)
	submitAs(cur, krakenKey, "kraken", 49050)
	p, _ := GetPrice(asset)
	if p != 48975 {
		t.Fatalf("act 4: published %d, want 48975 (median of the honest pair)", p)
	}
	if f.included != 2 {
		t.Fatalf("act 4: included %d, want 2", f.included)
	}
	if coingecko.hasSubmission && coingecko.isFresh(551) {
		t.Fatal("act 4: the attacker's stale entry must not count as fresh")
	}

	// Act 5: attack again against the fresh consistent reference.
	submitAs(cur, coingeckoK, "coingecko", 99200)
	if coingecko.rejected != 4 {
		t.Fatalf("act 5: rejected=%d, want 4", coingecko.rejected)
	}
	if p2, _ := GetPrice(asset); p2 != 48975 {
		t.Fatalf("act 5: median moved to %d, want 48975", p2)
	}
}
