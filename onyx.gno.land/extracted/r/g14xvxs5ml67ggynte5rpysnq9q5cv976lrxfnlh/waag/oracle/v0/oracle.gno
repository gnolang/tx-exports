package oracle

import (
	"strconv"

	"chain"
	"chain/runtime"

	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
)

// ---- Submissions ---------------------------------------------------------

// SubmitPrice records a price for one source. It is a crossing function: the
// `cur realm` parameter is how v1.8.0 hands a realm its caller context, and
// cur.Previous() is the caller one frame back - for a direct transaction from a
// wallet, that is the signer.
//
// Two outcomes are possible and they are deliberately different:
//
//   - A submission from the WRONG KEY, an unknown source, an invalid price, or
//     while paused PANICS. The transaction fails and every state change rolls
//     back. Nothing about that call was legitimate, so nothing is remembered.
//   - A submission that is legitimate but OUTLIER-priced is REJECTED without
//     panicking: the rejection is counted, an event is emitted, the price is
//     not stored, and the transaction succeeds. The feeder still paid gas, and
//     the feed keeps a public record that it refused a number and why. A revert
//     would hide exactly the evidence an operator needs during an incident.
//
// Argument order matches the master doc's quick reference: source, asset, price.
func SubmitPrice(cur realm, sourceID, asset string, price feedmath.Price) {
	if cfg.paused {
		panic("oracle: feed is paused")
	}

	f := mustFeed(asset)
	s := f.getSource(sourceID)
	if s == nil {
		panic("oracle: unknown source")
	}

	// Authorization (ledger O2): the signer must be the key registered for THIS
	// source. IsUserCall() is checked first so that another realm cannot call us
	// on a user's behalf and impersonate a feeder - the confused-deputy hole.
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("oracle: SubmitPrice requires a direct user call")
	}
	if caller.Address() != s.keyAddr {
		panic("oracle: caller is not the registered key for this source")
	}

	// Reject nonsense numbers before they can touch state. Panicking here is
	// right: a non-positive or absurd price is a broken feeder, not a market
	// condition, and it must not be stored or counted as a rejection.
	feedmath.MustValidPrice(price)

	height := runtime.ChainHeight()

	// Deviation guard (ledger O5, refined by O19): judged against the
	// CONSISTENT subset of the OTHER fresh sources - never a set including the
	// candidate, never anchored by a stored outlier.
	if ref, ok := f.deviationReference(sourceID, height); ok {
		if !feedmath.DeviationOK(price, ref, cfg.deviationBps) {
			bps := feedmath.DeviationBps(price, ref)
			s.rejected++
			s.lastRejectBps = bps
			chain.Emit(
				PriceRejectedEvent,
				"asset", asset,
				"source", sourceID,
				"price", strconv.FormatInt(int64(price), 10),
				"reference", strconv.FormatInt(int64(ref), 10),
				"deviation_bps", strconv.FormatInt(bps, 10),
				"limit_bps", strconv.FormatInt(cfg.deviationBps, 10),
			)
			return
		}
	}

	// Accepted: store it, then republish the median if a quorum is fresh.
	s.price = price
	s.height = height
	s.hasSubmission = true

	chain.Emit(
		PriceSubmittedEvent,
		"asset", asset,
		"source", sourceID,
		"price", strconv.FormatInt(int64(price), 10),
		"height", strconv.FormatInt(height, 10),
	)

	if f.recompute(height) {
		chain.Emit(
			MedianUpdatedEvent,
			"asset", asset,
			"median", strconv.FormatInt(int64(f.median), 10),
			"included", strconv.Itoa(f.included),
			"height", strconv.FormatInt(height, 10),
		)
	}
}

// ---- Reads ---------------------------------------------------------------

// GetPrice returns the published median for an asset and the height at which it
// was published.
//
// IT PANICS INSTEAD OF GUESSING. That is the product's central promise (ledger
// O12): a consumer that asks for a price while the feed is paused, has no
// quorum, or is stale gets a hard failure rather than a number that looks fine.
// Serving a rotten price quietly is how lending protocols get drained; refusing
// loudly is recoverable.
//
// Callers must handle the failure. In Gno that means the calling transaction
// reverts unless it isolates the call, so the consumer demo realm (O14) shows
// the frozen state explicitly rather than pretending the read always works.
//
// Freshness is re-checked HERE, at read time, from the stored per-source
// heights - not trusted from cached fields. A median published an hour ago from
// sources that have since gone quiet must not be servable, and only a read-time
// check guarantees that.
func GetPrice(asset string) (feedmath.Price, int64) {
	if cfg.paused {
		panic("oracle: feed is paused")
	}

	f := mustFeed(asset)
	if !f.published {
		panic("oracle: no price published yet")
	}

	height := runtime.ChainHeight()
	if !f.hasQuorum(height) {
		panic("oracle: not enough fresh sources to answer")
	}
	if !feedmath.IsFresh(f.medianAt, height, cfg.stalenessBlocks) {
		panic("oracle: published median is stale")
	}
	return f.median, f.medianAt
}

// GetSources returns a one-line-per-source status snapshot as text: id, last
// price, age in blocks, and whether it counts as fresh.
//
// Text rather than structs on purpose. A consumer realm reading this gets a
// stable string it cannot misinterpret, and it avoids exporting struct types
// across a realm boundary, which is a compatibility trap for v0.
func GetSources(asset string) string {
	f := mustFeed(asset)
	height := runtime.ChainHeight()

	lines := []string{}
	f.sources.Iterate("", "", func(sourceID string, value any) bool {
		s, ok := value.(*source)
		if !ok {
			return false
		}
		status := "NO DATA"
		age := int64(-1)
		if s.hasSubmission {
			age = feedmath.BlockAge(s.height, height)
			switch {
			case !s.isFresh(height):
				status = "STALE"
			case f.isOutlier(s, height):
				status = "OUTLIER" // fresh but culled from the median (O19)
			default:
				status = "FRESH"
			}
		}
		line := sourceID +
			" price=" + formatUSD(s.price) +
			" age=" + formatAge(age) +
			" status=" + status +
			" rejected=" + strconv.FormatInt(s.rejected, 10)
		lines = append(lines, line)
		return false
	})

	header := "asset=" + asset +
		" fresh=" + strconv.Itoa(f.countFresh(height)) +
		"/" + strconv.Itoa(f.sources.Size()) +
		" quorum=" + strconv.Itoa(cfg.minFreshSources)
	if len(lines) == 0 {
		return header + "\n(no sources registered)"
	}
	out := header
	for _, l := range lines {
		out += "\n" + l
	}
	return out
}
