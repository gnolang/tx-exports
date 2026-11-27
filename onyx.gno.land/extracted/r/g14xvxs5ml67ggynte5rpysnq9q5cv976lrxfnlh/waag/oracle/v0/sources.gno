// Package oracle is a multi-source GNOT/USD price feed for gno.land.
//
// Three registered sources (one exchange/API each) submit prices from their own
// keys. The feed publishes the MEDIAN of the submissions that are still fresh,
// and refuses to answer at all when it cannot be trusted - rather than serving a
// stale or under-supported number.
//
// Design decisions, all owner-approved and recorded in the master build doc:
//
//	O2  one key per source, enforced on-chain (a wrong key cannot submit)
//	O3  aggregate by median, not mean (one bad quote cannot move it)
//	O5  reject a submission deviating > 10% from the other fresh sources
//	O6  a source is fresh for 300 blocks; answering needs >= 2 of 3 fresh
//	O7  prices are integers scaled by 1e6 - no floats on-chain
//	O11 no "anyone may set any price" switch, not even for demos
//	O19 only a mutually CONSISTENT subset of the fresh sources publishes or
//	    anchors the guard: sources disagreeing with the fresh set's median are
//	    culled, so one compromised key cannot poison the median during a
//	    no-reference window, and a disagreeing pair freezes instead of
//	    publishing a coin-flip midpoint
//
// Everything numeric lives in the feedmath package. This realm holds state,
// authorization and events only: if a rule about prices is wrong, the bug is in
// feedmath and its tests catch it there.
//
// API verified 2026-11-25 against gnolang/gno tag v1.8.0:
//
//	examples/gno.land/p/nt/avl/v0        Tree zero value is usable; Get returns
//	                                     nil when absent; values are `any`
//	examples/gno.land/r/archive/boards   the nested-tree pattern used here:
//	                                     outer tree stores *struct, inner
//	                                     avl.Tree is a value field
//	gnovm/stdlibs/chain/emit_event.gno   chain.Emit(typ string, attrs ...string),
//	                                     attrs are key/value pairs
//	gnovm/stdlibs/chain/runtime          ChainHeight() int64, Realm.Previous(),
//	                                     IsUserCall(), Address()
package oracle

import (
	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
	"gno.land/p/nt/avl/v0"
)

// ---- Event names ---------------------------------------------------------
//
// chain.Emit takes a type string plus an even number of attribute strings,
// read as key/value pairs. Events are how an off-chain watcher (or the feeder
// bot's own logs) can see what the feed did without parsing Render output.

const (
	PriceSubmittedEvent   = "PriceSubmitted"
	PriceRejectedEvent    = "PriceRejected"
	MedianUpdatedEvent    = "MedianUpdated"
	SourceRegisteredEvent = "SourceRegistered"
	SourceRemovedEvent    = "SourceRemoved"
	ConfigChangedEvent    = "ConfigChanged"
	PausedEvent           = "Paused"
)

// ---- Types ---------------------------------------------------------------

// source is one registered price source: who is allowed to speak for it, and
// what it last said.
//
// Stored as a POINTER inside feed.sources. That matters: avl.Tree values are
// `any`, so storing a struct by value would hand back a copy and mutations
// would silently vanish. The pointer is what makes updates stick, and it is the
// same pattern r/archive/boards uses.
type source struct {
	id      string  // "kucoin", "kraken", "coingecko"
	asset   string  // "GNOT"
	keyAddr address // the ONLY address that may submit for this source

	price         feedmath.Price // last ACCEPTED price
	height        int64          // block height of that acceptance
	hasSubmission bool           // false until the first accepted price

	rejected      int64 // how many submissions the deviation guard refused
	lastRejectBps int64 // deviation of the most recent refusal, in basis points
}

// feed is everything the oracle knows about one asset.
//
// sources is an avl.Tree rather than a slice so that looking one source up by
// id costs O(log n) storage reads instead of loading the whole list - cheap now
// with three sources, and it does not degrade if assets or sources are added.
type feed struct {
	asset   string
	sources avl.Tree // sourceID -> *source

	// The published answer. It is only rewritten when a submission arrives and
	// at least minFreshSources sources are fresh; GetPrice re-checks freshness
	// at read time rather than trusting these fields blindly.
	median    feedmath.Price
	medianAt  int64 // height at which the median was last published
	included  int   // how many fresh sources went into it
	published bool  // false until the first quorum is reached
}

// config holds the tunable rules. Every field is admin-settable so the
// thresholds can be retuned during burn-in without redeploying the realm.
type config struct {
	stalenessBlocks int64 // O6: how long a submission stays fresh
	deviationBps    int64 // O5: rejection threshold, basis points
	minFreshSources int   // O6: quorum needed to answer at all
	paused          bool  // emergency stop: everything reverts
}

// Shipped defaults, matching ledger O5/O6.
const (
	DefaultStalenessBlocks = int64(300)
	DefaultDeviationBps    = int64(1000) // 10%
	DefaultMinFreshSources = 2           // of 3 registered sources
)

// ---- State ---------------------------------------------------------------
//
// Package-level vars in a realm are stored on-chain and survive between
// transactions, paid for by the realm's storage deposit.

var feeds avl.Tree // asset -> *feed

var cfg = config{
	stalenessBlocks: DefaultStalenessBlocks,
	deviationBps:    DefaultDeviationBps,
	minFreshSources: DefaultMinFreshSources,
	paused:          false,
}

// ---- Lookups -------------------------------------------------------------

// getFeed returns the feed for an asset, or nil when the asset is unknown.
func getFeed(asset string) *feed {
	f, ok := feeds.Get(asset).(*feed)
	if !ok {
		return nil
	}
	return f
}

// mustFeed returns the feed for an asset or panics. A caller naming an asset
// the oracle was never told about is a mistake, not a market condition, so it
// gets a clear revert instead of a silent zero.
func mustFeed(asset string) *feed {
	f := getFeed(asset)
	if f == nil {
		panic("oracle: unknown asset")
	}
	return f
}

// getSource returns one registered source, or nil.
func (f *feed) getSource(sourceID string) *source {
	s, ok := f.sources.Get(sourceID).(*source)
	if !ok {
		return nil
	}
	return s
}

// isFresh reports whether this source's last accepted submission still counts,
// per ledger O6. A source that has never submitted is never fresh.
func (s *source) isFresh(atHeight int64) bool {
	if !s.hasSubmission {
		return false
	}
	return feedmath.IsFresh(s.height, atHeight, cfg.stalenessBlocks)
}
