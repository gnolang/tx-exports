package oracle

import (
	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
)

// This file holds the two decisions that protect the published number: which
// reference price the deviation guard compares against, and whether enough
// sources are fresh to answer at all. Both are read-only - they inspect state
// and change nothing.

// freshPrices collects the accepted prices of every source whose last
// submission is still inside the staleness window, skipping the source named by
// excludeID (pass "" to skip nobody).
//
// The order of the returned slice follows the avl tree's key order, which is
// sourceID sorted alphabetically. That is deterministic across nodes, which
// matters: a median must not depend on map iteration luck. MedianN copies and
// sorts anyway, so the incoming order cannot change the answer.
func (f *feed) freshPrices(excludeID string, atHeight int64) []feedmath.Price {
	out := []feedmath.Price{}
	f.sources.Iterate("", "", func(sourceID string, value any) bool {
		s, ok := value.(*source)
		if !ok {
			return false // keep going; a malformed entry must not stop the scan
		}
		if sourceID == excludeID {
			return false
		}
		if s.isFresh(atHeight) {
			out = append(out, s.price)
		}
		return false // false = do not stop early
	})
	return out
}

// countFresh returns how many sources currently count, per ledger O6.
func (f *feed) countFresh(atHeight int64) int {
	n := 0
	f.sources.Iterate("", "", func(_ string, value any) bool {
		if s, ok := value.(*source); ok && s.isFresh(atHeight) {
			n++
		}
		return false
	})
	return n
}

// consistentSubset culls prices that disagree with the group (ledger O19).
//
// The anchor is the set's own median: any price deviating from it by more than
// thresholdBps is dropped. A single pass, deliberately - with three sources an
// iterate-to-fixpoint cull could not change the outcome, and one pass is easy
// to reason about.
//
// Why the median is the right anchor: it takes a majority to move it. With one
// wild price among honest ones, the median stays inside the honest cluster and
// the wild one is culled. With a wildly disagreeing PAIR there is no majority:
// the midpoint sits >threshold away from both (once they are more than 2x the
// threshold apart), so both are culled and nothing is trustworthy - which is
// the honest answer. A coin-flip midpoint is worse than "no data" (O12).
//
// The known limit, unchanged and unfixable by any median-style rule: two
// compromised sources that agree with each other outvote one honest one.
func consistentSubset(prices []feedmath.Price, thresholdBps int64) []feedmath.Price {
	if len(prices) == 0 {
		return prices
	}
	anchor := feedmath.MedianN(prices)
	out := []feedmath.Price{}
	for _, p := range prices {
		if feedmath.DeviationOK(p, anchor, thresholdBps) {
			out = append(out, p)
		}
	}
	return out
}

// consistentFresh returns the fresh prices that agree with each other: the
// fresh set minus anyone culled by consistentSubset.
func (f *feed) consistentFresh(atHeight int64) []feedmath.Price {
	return consistentSubset(f.freshPrices("", atHeight), cfg.deviationBps)
}

// deviationReference picks the price a new submission is judged against.
//
// Ledger O5 as refined by O19, in order of preference:
//
//  1. The median of the CONSISTENT subset of the OTHER fresh sources.
//     "Other" - never a set including the candidate - stops a submitter from
//     anchoring the reference to its own lie. "Consistent" stops a stored
//     poison value (accepted during a no-reference bootstrap window) from
//     anchoring the reference against the honest majority.
//  2. Otherwise, if fewer than two others survive the cull, the last published
//     median. A single honest source is too thin to judge by on its own, but a
//     median that already commanded a quorum is a reasonable bar.
//  3. Otherwise, no reference at all - the bootstrap case. Blocking here would
//     make the feed impossible to start, so the guard stands aside. This can
//     only happen before the FIRST publication: from then on step 2 always has
//     a median to offer, so the window never reopens (an outage falls back to
//     the last published number rather than to nothing).
//
// The second return value reports whether a reference exists. Callers must
// check it rather than comparing against a meaningless zero price.
func (f *feed) deviationReference(excludeID string, atHeight int64) (feedmath.Price, bool) {
	others := f.freshPrices(excludeID, atHeight)
	survivors := consistentSubset(others, cfg.deviationBps)
	if len(survivors) >= 2 {
		return feedmath.MedianN(survivors), true
	}
	if f.published {
		return f.median, true
	}
	return 0, false
}

// hasQuorum reports whether enough sources are fresh to publish an answer.
func (f *feed) hasQuorum(atHeight int64) bool {
	return f.countFresh(atHeight) >= cfg.minFreshSources
}

// recompute republishes the median from the currently fresh sources.
//
// Ledger O19: only the CONSISTENT subset publishes. Fresh sources whose prices
// disagree with the fresh set's own median are culled, and quorum is then
// required among the SURVIVORS - so a compromised source can never contribute
// to the published number, and a wildly disagreeing pair freezes the feed
// instead of publishing a coin-flip midpoint.
//
// It only writes when a quorum of survivors exists. Falling below quorum does
// NOT erase the last median: the number stays on the dashboard as history, and
// GetPrice refuses to serve it because its freshness/quorum checks fail at
// read time. Erasing it would destroy the evidence of what the feed last
// believed, which is exactly what an operator debugging an outage needs.
//
// Returns true when the published median changed.
func (f *feed) recompute(atHeight int64) bool {
	survivors := f.consistentFresh(atHeight)
	if len(survivors) < cfg.minFreshSources {
		return false
	}
	median := feedmath.MedianN(survivors)

	changed := !f.published || f.median != median || f.included != len(survivors)
	f.median = median
	f.medianAt = atHeight
	f.included = len(survivors)
	f.published = true
	return changed
}

// isOutlier reports whether s is fresh but culled from the consistent subset -
// the dashboard marks such a source OUTLIER so an operator can see at a glance
// that it is stored and fresh yet excluded from the published median (a
// compromised or badly broken feeder looks exactly like this).
func (f *feed) isOutlier(s *source, atHeight int64) bool {
	if !s.isFresh(atHeight) {
		return false
	}
	prices := f.freshPrices("", atHeight)
	if len(prices) == 0 {
		return false
	}
	anchor := feedmath.MedianN(prices)
	return !feedmath.DeviationOK(s.price, anchor, cfg.deviationBps)
}
