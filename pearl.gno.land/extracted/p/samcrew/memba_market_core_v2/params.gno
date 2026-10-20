// Package memba_market_core holds the frozen, cross-engine money math and event
// schema for the Memba NFT marketplace engines. It is a PURE package (no chain/
// realm imports): split math returns values, event helpers return ordered arg
// slices, and the importing engine performs chain.Emit / banker / MarketTransfer.
//
// Constants are copied verbatim from memba_nft_market_v3 (the deployed reference).
// SplitProceeds must stay behaviorally identical to v3's splitProceeds so every
// engine pays out identically (fee/royalty conformance).
package memba_market_core_v2

import "strconv"

const (
	FeeBPS        = int64(200)                   // 2.0% default platform fee (matches v3)
	MaxFeeBPS     = int64(500)                   // 5% hard ceiling on any per-lane fee (DAO cannot exceed)
	MaxRoyaltyBPS = int64(1000)                  // 10% royalty clamp (defense-in-depth)
	MinPrice      = int64(1000)                  // 0.001 GNOT — prevents fee truncation to zero at FeeBPS
	MaxPrice      = int64(1_000_000_000_000_000) // 1 billion GNOT

	// SettlementDenom is carried on every settlement event for forward-compat with
	// the GRC20 settlement desk (PHASE 3+). Engines settle in ugnot today.
	SettlementDenom = "ugnot"

	// SchemaVersion stamps every event so the indexer can branch parsing
	// deterministically and the schema can evolve without ambiguity. Bump ONLY
	// when an event's key set changes; never reuse a version for a different shape.
	SchemaVersion = "1"
)

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
