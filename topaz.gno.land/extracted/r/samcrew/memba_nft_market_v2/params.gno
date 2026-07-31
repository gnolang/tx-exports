package memba_nft_market_v2

// Platform constants — single source of truth for all fee math and caps.

const (
	FeeBPS             = int64(250)                   // 2.5% platform fee
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
)
