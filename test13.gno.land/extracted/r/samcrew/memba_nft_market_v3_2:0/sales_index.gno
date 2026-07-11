package memba_nft_market_v3_2

// v3.2 — purchase-query index + getters (the marketplace-v2 Phase 6 unlock).
//
// v3.1 recorded every settlement in salesLog but exposed NO purchase-query read,
// so purchase-gated reviews had nothing to gate on (ungated reputation is
// sybil-farmable — worse than none). v3.2 maintains two secondary indexes,
// written by the same recordSale that appends the log:
//
//	buyerSellerIdx  "buyer:seller"        -> int64 sale count
//	salesByBuyer    "buyer:pad(saleId)"   -> int64 saleId (per-buyer, sale order)
//
// and exposes HasPurchased / PurchaseCount / GetSalesByBuyer. Reads use the
// same prefix-range technique as GetOffersForToken (":" .. ";") — never a
// full-tree scan.
//
// Historical v3.1 sales enter through the sealed SeedSale migration: owner-only,
// NON-payable (never reads OriginSend / moves funds), one-way FinalizeSaleSeed
// latch — the exact SeedListing/FinalizeSeed precedent from memba_appstore_v3.

import (
	"strings"

	"chain"

	"gno.land/p/nt/avl/v0"
)

var (
	buyerSellerIdx *avl.Tree // "buyer:seller" -> int64 count
	salesByBuyer   *avl.Tree // "buyer:pad(saleId)" -> int64 saleId
	saleSeedSealed bool
)

func init() {
	buyerSellerIdx = avl.NewTree()
	salesByBuyer = avl.NewTree()
}

// pad renders a saleId fixed-width so string ordering == numeric ordering
// inside a buyer's prefix range. 12 digits outlives any plausible sale count.
func pad(n int64) string {
	s := itoa(n)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

// indexSale is called by recordSale (and SeedSale) with an already-persisted
// sale. It only maintains the secondary indexes — salesLog stays the source
// of truth.
func indexSale(seller, buyer address, saleId int64) {
	bk := buyer.String() + ":" + seller.String()
	cnt := int64(0)
	if v, ok := buyerSellerIdx.Get(bk); ok {
		cnt = v.(int64)
	}
	buyerSellerIdx.Set(bk, cnt+1)
	salesByBuyer.Set(buyer.String()+":"+pad(saleId), saleId)
}

// ── Read getters (pure, non-failing) ─────────────────────────────────────────

// HasPurchased reports whether buyer has at least one settled purchase from
// seller on this engine. THE purchase-gate primitive for reviews: a consumer
// realm calls this before accepting a buyer's review of a seller.
func HasPurchased(buyerStr, sellerStr string) bool {
	return buyerSellerIdx.Has(buyerStr + ":" + sellerStr)
}

// PurchaseCount returns how many settled purchases buyer has made from seller.
func PurchaseCount(buyerStr, sellerStr string) int64 {
	if v, ok := buyerSellerIdx.Get(buyerStr + ":" + sellerStr); ok {
		return v.(int64)
	}
	return 0
}

// GetSalesByBuyer returns a page of the buyer's settled purchases in sale
// order, one per line:
//
//	saleId|collectionID|tokenID|seller|price|blk
//
// Addresses are FULL. limit is clamped to [1, MaxPageSize]; offset skips
// forward inside the buyer's prefix range (bounded by the page clamp — the
// iteration stops as soon as the page is full).
func GetSalesByBuyer(buyerStr string, offset, limit int) string {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > MaxPageSize {
		limit = MaxPageSize
	}
	start := buyerStr + ":"
	end := buyerStr + ";" // ';' (0x3b) is the byte after ':' (0x3a)

	var sb strings.Builder
	skipped, taken := 0, 0
	salesByBuyer.Iterate(start, end, func(_ string, v interface{}) bool {
		if skipped < offset {
			skipped++
			return false
		}
		if taken >= limit {
			return true // page full — stop iterating
		}
		saleId := v.(int64)
		sv, ok := salesLog.Get(itoa(saleId))
		if !ok {
			return false // index without log row — skip defensively
		}
		s := sv.(*Sale)
		sb.WriteString(itoa(saleId))
		sb.WriteString("|")
		sb.WriteString(s.CollectionID)
		sb.WriteString("|")
		sb.WriteString(s.TokenID)
		sb.WriteString("|")
		sb.WriteString(s.Seller.String())
		sb.WriteString("|")
		sb.WriteString(itoa(s.Price))
		sb.WriteString("|")
		sb.WriteString(itoa(s.Blk))
		sb.WriteString("\n")
		taken++
		return false
	})
	return sb.String()
}

// ── Migration (owner-only, sealable) ─────────────────────────────────────────

// SeedSale imports one historical v3.1 sale verbatim (its original block height,
// price and fee/royalty split). Owner-only, NON-payable, and permanently sealed
// by FinalizeSaleSeed — without the latch this would be a standing backdoor to
// forge purchase history and defeat the review gate.
func SeedSale(
	cur realm,
	collectionID, tokenID string,
	sellerStr, buyerStr string,
	price, fee, royalty, blk int64,
) {
	assertAdmin()
	if saleSeedSealed {
		panic("sale seeding sealed — migration is finalized")
	}
	if collectionID == "" || tokenID == "" {
		panic("empty collection/token id")
	}
	if sellerStr == "" || buyerStr == "" {
		panic("empty seller/buyer address")
	}
	if price < 0 || fee < 0 || royalty < 0 || fee+royalty > price {
		panic("invalid price/fee/royalty split")
	}
	if blk < 0 {
		panic("invalid block height")
	}
	seller := address(sellerStr)
	buyer := address(buyerStr)

	nextSaleId++
	salesLog.Set(itoa(nextSaleId), &Sale{
		CollectionID: collectionID,
		TokenID:      tokenID,
		Seller:       seller,
		Buyer:        buyer,
		Price:        price,
		Fee:          fee,
		Royalty:      royalty,
		Blk:          blk,
	})
	indexSale(seller, buyer, nextSaleId)
	// Keep the Render volume stat truthful across the migration.
	totalVolume += price
	chain.Emit("SaleSeeded", "saleId", itoa(nextSaleId), "collectionID", collectionID)
}

// FinalizeSaleSeed permanently seals SeedSale (one-way latch). Owner-only.
func FinalizeSaleSeed(cur realm) {
	assertAdmin()
	saleSeedSealed = true
	chain.Emit("SaleSeedingFinalized")
}
