package memba_nft_market_v3_2

// v3.1 — structured read getters.
//
// These let the frontend read listings and offers STRUCTURALLY (full addresses,
// deterministic format) instead of scraping the markdown Render(""), which truncated
// addresses and capped at 50 rows. Output is one record per line, pipe-delimited, so
// the client parses by split — no markdown regex, no truncation.

import (
	"strings"

	"chain/runtime/unsafe"
)

// MaxPageSize bounds a single page so a getter can never iterate unboundedly (a
// gas/DoS surface). The frontend pages with offset/limit.
const MaxPageSize = 100

// MarketAddress returns this engine realm's own address — the operator a seller
// approves on the collection (SetApprovalForAll) and the address the collection
// registers via RegisterMarket. Exposed so the frontend and the deploy ceremony can
// read the deterministic address directly instead of hardcoding it.
func MarketAddress() string { return unsafe.CurrentRealm().Address().String() }

// ── NF-2 solvency getters (MAINNET_READINESS §3) ─────────────────────────────
//
// The offer escrow makes this a pooled-fund realm: without a machine-readable
// liabilities figure the solvency monitor can only do a balance-only heuristic.
// Invariant the monitor reconciles: realm balance >= TotalLiabilities().

// TotalLiabilities returns the total ugnot the realm owes to offer escrows.
// Maintained in lockstep with every escrow mutation (see offers.gno).
func TotalLiabilities() int64 { return totalEscrowed }

// RealmAddress is the NF-2 canonical name for the realm's own address (the
// monitor pairs it with TotalLiabilities). Same value as MarketAddress.
func RealmAddress() string { return MarketAddress() }

// ListingsCount returns the number of active listings (for pagination).
func ListingsCount() int { return len(listingOrder) }

// GetListingsPage returns a page of active listings, one per line:
//
//	collectionID|tokenID|seller|price|createdBlk
//
// Addresses are FULL (never truncated). offset/limit window the insertion-ordered
// listing set; limit is clamped to [1, MaxPageSize].
func GetListingsPage(offset, limit int) string {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > MaxPageSize {
		limit = MaxPageSize
	}
	n := len(listingOrder)
	end := offset + limit
	if end > n {
		end = n
	}

	var sb strings.Builder
	for i := offset; i < end; i++ {
		v, ok := listings.Get(listingOrder[i])
		if !ok {
			continue
		}
		l := v.(*Listing)
		sb.WriteString(l.CollectionID)
		sb.WriteString("|")
		sb.WriteString(l.TokenID)
		sb.WriteString("|")
		sb.WriteString(l.Seller.String())
		sb.WriteString("|")
		sb.WriteString(itoa(l.Price))
		sb.WriteString("|")
		sb.WriteString(itoa(l.CreatedBlk))
		sb.WriteString("\n")
	}
	return sb.String()
}

// GetOffersForToken returns the active offers on one (collection, token), one per line:
//
//	buyer|amount|createdBlk
//
// It uses a PREFIX-RANGE scan over the offer tree — offerKey is "collection:token:buyer",
// so the range ["collection:token:", "collection:token;") reads only this token's
// offers, never a full-tree scan. This is the read that finally lets the frontend wire
// accept-offer and show a token's offers (no offers getter existed before v3.1).
func GetOffersForToken(collectionID, tokenID string) string {
	start := collectionID + ":" + tokenID + ":"
	end := collectionID + ":" + tokenID + ";" // ';' (0x3b) is the byte after ':' (0x3a)

	var sb strings.Builder
	offers.Iterate(start, end, func(_ string, v interface{}) bool {
		o := v.(*Offer)
		sb.WriteString(o.Buyer.String())
		sb.WriteString("|")
		sb.WriteString(itoa(o.Amount))
		sb.WriteString("|")
		sb.WriteString(itoa(o.CreatedBlk))
		sb.WriteString("\n")
		return false
	})
	return sb.String()
}
