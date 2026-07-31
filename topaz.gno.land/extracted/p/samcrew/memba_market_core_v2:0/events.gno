package memba_market_core_v2

// Frozen cross-engine event schema. Every settlement event an engine emits MUST
// be built here so name + ordered key set are identical across engines and the
// indexer/frontend parse one schema. Append "schemaVersion" last on every event.
// Engines call: chain.Emit(SaleEvent, SaleArgs(...)...).

const SaleEvent = "Sale"

// SaleArgs builds the ONE canonical settlement event for a completed sale, keyed
// by `via` ("buy" | "offer" | "auction" | "sweep"). Key order matches
// memba_nft_market_v3.emitSale verbatim, with "schemaVersion" appended, so the
// existing indexer parses v3 and future engines identically.
func SaleArgs(via, collection, tokenID, seller, buyer string, price, fee, royalty int64, royaltyRecipient string, sellerAmount int64, denom string) []string {
	return []string{
		"via", via,
		"collection", collection,
		"tokenId", tokenID,
		"seller", seller,
		"buyer", buyer,
		"price", itoa(price),
		"fee", itoa(fee),
		"royalty", itoa(royalty),
		"royaltyRecipient", royaltyRecipient,
		"sellerAmount", itoa(sellerAmount),
		"denom", denom,
		"schemaVersion", SchemaVersion,
	}
}

// ── Offer lifecycle (Phase 2). Accepted offers emit SaleEvent via SaleArgs("offer",…). ──
// NOTE: The live memba_nft_market_v3 realm already emits OfferMade/OfferCancelled events.
// Engines using these builders are a DIFFERENT realm (distinct pkg_path) and stamp schemaVersion,
// so the indexer disambiguates by pkg_path + schemaVersion.

const (
	OfferMadeEvent      = "OfferMade"
	OfferAcceptedEvent  = "OfferAccepted" // reserved; accept emits SaleEvent (via="offer")
	OfferCancelledEvent = "OfferCancelled"
)

func OfferMadeArgs(collection, tokenID, buyer string, amount int64, denom string, expiryBlock int64) []string {
	return []string{
		"collection", collection, "tokenId", tokenID, "buyer", buyer,
		"amount", itoa(amount), "denom", denom, "expiryBlock", itoa(expiryBlock),
		"schemaVersion", SchemaVersion,
	}
}

func OfferCancelledArgs(collection, tokenID, buyer string, amount int64) []string {
	return []string{
		"collection", collection, "tokenId", tokenID, "buyer", buyer, "amount", itoa(amount),
		"schemaVersion", SchemaVersion,
	}
}

// ── Auction lifecycle (Phase 3). Settled auctions emit SaleEvent via SaleArgs("auction",…). ──

const (
	AuctionCreatedEvent  = "AuctionCreated"
	BidPlacedEvent       = "BidPlaced"
	BidRefundedEvent     = "BidRefunded"
	AuctionExtendedEvent = "AuctionExtended"
	AuctionSettledEvent  = "AuctionSettled" // reserved; settle emits SaleEvent (via="auction")
)

func AuctionCreatedArgs(collection, tokenID, seller string, reserve int64, denom string, endBlock int64) []string {
	return []string{
		"collection", collection, "tokenId", tokenID, "seller", seller,
		"reserve", itoa(reserve), "denom", denom, "endBlock", itoa(endBlock),
		"schemaVersion", SchemaVersion,
	}
}

func BidPlacedArgs(collection, tokenID, bidder string, amount int64, denom string, newEndBlock int64) []string {
	return []string{
		"collection", collection, "tokenId", tokenID, "bidder", bidder,
		"amount", itoa(amount), "denom", denom, "newEndBlock", itoa(newEndBlock),
		"schemaVersion", SchemaVersion,
	}
}

func BidRefundedArgs(collection, tokenID, bidder string, amount int64, denom string) []string {
	return []string{
		"collection", collection, "tokenId", tokenID, "bidder", bidder,
		"amount", itoa(amount), "denom", denom,
		"schemaVersion", SchemaVersion,
	}
}

// ── Sweep summary (Phase 2). Each filled unit also emits SaleEvent via SaleArgs("sweep",…). ──

const SweepExecutedEvent = "SweepExecuted"

func SweepExecutedArgs(buyer string, count int, totalSpent int64, denom string) []string {
	return []string{
		"buyer", buyer, "count", itoa(int64(count)), "totalSpent", itoa(totalSpent),
		"denom", denom, "schemaVersion", SchemaVersion,
	}
}
