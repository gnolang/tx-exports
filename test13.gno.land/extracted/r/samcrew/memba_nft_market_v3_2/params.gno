package memba_nft_market_v3_2

// Platform constants — single source of truth for all fee math and caps.

const (
	FeeBPS             = int64(200)                   // v3 change #1: 2.0% platform fee (was 2.5% / 250 bps in v2)
	MaxRoyaltyBPS      = int64(1000)                  // 10% maximum royalty (defense-in-depth clamp)
	MinPrice           = int64(1000)                  // 0.001 GNOT — prevents fee truncation to zero
	MaxPrice           = int64(1_000_000_000_000_000) // 1 billion GNOT
	OfferTimeoutBlk    = int64(302400)                // ~7 days at 2 s/block
	MinOfferLifetimeBlk = int64(10)                   // offer must live ≥ 10 blocks before cancel
	MaxListings        = 1000
	MaxOffers          = 1000
	MaxListingsPerAddr = 50
	MaxOffersPerAddr   = 50
	AdminAddress       = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

	// v3 change #2: settlement payment denom. Carried on every settlement event for
	// forward-compat with the GRC20 settlement desk (PHASE 3+). Today, the engine
	// only settles in ugnot.
	SettlementDenom = "ugnot"
)
