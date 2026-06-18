package memba_nft_market_v2

// NFT Marketplace v2 — General-purpose NFT trading for the Memba ecosystem on test13.
//
// Supports the memba_nft_v2 collection realm via cross-realm MarketTransfer.
// Platform fee: 2.5% to AdminAddress multisig.
// Royalty: clamped to MaxRoyaltyBPS (10%), returned by nft.RoyaltyInfo().
//
// Security:
//   - CEI (Checks-Effects-Interactions) in all payment flows
//   - IsUserCall guard on BuyNFT and MakeOffer (payment-bearing fns)
//   - Offer escrow with OfferTimeoutBlk safety valve (ClaimExpiredOffer)
//   - MinOfferLifetimeBlk prevents instant-cancel front-run
//   - Only original lister can delist (pause-exempt exit)
//   - Self-buy prevention
//   - Defense-in-depth royalty clamp even when collection enforces its own cap

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/samcrew/grc721"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	nft "gno.land/r/samcrew/memba_nft_v2"
)

// ── Types ─────────────────────────────────────────────────────────────────────

// Listing represents a fixed-price sale order.
type Listing struct {
	CollectionID string
	TokenID      string
	Seller       address
	Price        int64
	CreatedBlk   int64
}

// Sale records a completed transaction for the salesLog.
type Sale struct {
	CollectionID string
	TokenID      string
	Seller       address
	Buyer        address
	Price        int64
	Fee          int64
	Royalty      int64
	Blk          int64
}

// ── State ─────────────────────────────────────────────────────────────────────

var (
	listings     *avl.Tree // listingKey -> *Listing
	offers       *avl.Tree // offerKey   -> *Offer
	salesLog     *avl.Tree // itoa(saleId) -> *Sale
	listingOrder []string  // insertion-ordered listing keys (pagination)
	nextSaleId   int64
	totalVolume  int64
	paused       bool
	feeRecipient = address(AdminAddress)
)

func init() {
	listings = avl.NewTree()
	offers = avl.NewTree()
	salesLog = avl.NewTree()
}

// ── Key helpers ───────────────────────────────────────────────────────────────

func listingKey(collectionID, tokenID string) string {
	return collectionID + ":" + tokenID
}

func offerKey(collectionID, tokenID string, buyer address) string {
	return collectionID + ":" + tokenID + ":" + string(buyer)
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// sumUgnot returns the total ugnot in a coin set.
func sumUgnot(coins chain.Coins) int64 {
	for _, c := range coins {
		if c.Denom == "ugnot" {
			return c.Amount
		}
	}
	return 0
}

// removeFromOrder removes a key from the ordered listing slice (O(n)).
func removeFromOrder(key string) {
	for i, k := range listingOrder {
		if k == key {
			listingOrder = append(listingOrder[:i], listingOrder[i+1:]...)
			return
		}
	}
}

// countListingsBySeller counts a seller's open listings. Bounded by MaxListings.
func countListingsBySeller(seller address) int {
	n := 0
	listings.Iterate("", "", func(_ string, v interface{}) bool {
		if v.(*Listing).Seller == seller {
			n++
		}
		return false
	})
	return n
}

// countOffersByBuyer counts a buyer's open offers. Bounded by MaxOffers.
func countOffersByBuyer(buyer address) int {
	n := 0
	offers.Iterate("", "", func(_ string, v interface{}) bool {
		if v.(*Offer).Buyer == buyer {
			n++
		}
		return false
	})
	return n
}

// ── List / Delist ─────────────────────────────────────────────────────────────

// ListNFT lists an NFT for fixed-price sale.
// PREREQUISITE: Owner must call nft.SetApprovalForAll(marketplace, true) first so
// MarketTransfer can execute on behalf of the seller.
func ListNFT(cur realm, collectionID string, tid grc721.TokenID, price int64) {
	if paused {
		panic("market paused")
	}
	seller := unsafe.PreviousRealm().Address()

	if price < MinPrice {
		panic(ufmt.Sprintf("price must be >= %d ugnot", MinPrice))
	}
	if price > MaxPrice {
		panic(ufmt.Sprintf("price must be <= %d ugnot", MaxPrice))
	}
	if listings.Size() >= MaxListings {
		panic("marketplace listing limit reached")
	}
	if countListingsBySeller(seller) >= MaxListingsPerAddr {
		panic("seller listing limit reached")
	}

	key := listingKey(collectionID, string(tid))
	if _, exists := listings.Get(key); exists {
		panic("already listed: " + key)
	}

	// Effects
	listings.Set(key, &Listing{
		CollectionID: collectionID,
		TokenID:      string(tid),
		Seller:       seller,
		Price:        price,
		CreatedBlk:   runtime.ChainHeight(),
	})
	listingOrder = append(listingOrder, key)

	chain.Emit("NFTListed",
		"collection", collectionID,
		"tokenId", string(tid),
		"seller", seller.String(),
		"price", itoa(price),
	)
}

// DelistNFT removes a listing. Only the original lister can delist. Pause-exempt
// (value-exit: unwinds the seller's position).
func DelistNFT(cur realm, collectionID string, tid grc721.TokenID) {
	caller := unsafe.PreviousRealm().Address()
	key := listingKey(collectionID, string(tid))

	val, exists := listings.Get(key)
	if !exists {
		panic("not listed: " + key)
	}
	l := val.(*Listing)
	if l.Seller != caller {
		panic("only seller can delist")
	}

	// Effects
	listings.Remove(key)
	removeFromOrder(key)

	chain.Emit("NFTDelisted",
		"collection", collectionID,
		"tokenId", string(tid),
		"seller", caller.String(),
	)
}

// ── Buy ───────────────────────────────────────────────────────────────────────

// BuyNFT purchases a listed NFT atomically (CEI order).
//
// CEI:
//   Checks  — paused / IsUserCall / listed / self-buy / payment amount
//   Effects — remove listing from state, record sale, update volume
//   Interactions — cross-call MarketTransfer, then banker payouts (seller last)
func BuyNFT(cur realm, collectionID string, tid grc721.TokenID) {
	if paused {
		panic("market paused")
	}
	if !unsafe.PreviousRealm().IsUserCall() {
		panic("must be a direct user call")
	}
	key := listingKey(collectionID, string(tid))
	v, ok := listings.Get(key)
	if !ok {
		panic("listing not found")
	}
	l := v.(*Listing)
	buyer := unsafe.PreviousRealm().Address()
	if buyer == l.Seller {
		panic("cannot buy own listing")
	}
	if sumUgnot(unsafe.OriginSend()) != l.Price {
		panic("incorrect payment")
	}

	royRecip, royAmt := nft.RoyaltyInfo(collectionID, tid, l.Price)
	fee, royalty, sellerAmt := splitProceeds(l.Price, royAmt)

	// Effects (before cross-call + sends)
	seller := l.Seller
	price := l.Price
	listings.Remove(key)
	removeFromOrder(key)
	recordSale(collectionID, string(tid), seller, buyer, price, fee, royalty)
	totalVolume += price

	// Interactions
	nft.MarketTransfer(cross(cur), collectionID, seller, buyer, tid)
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	self := unsafe.CurrentRealm().Address()
	if royalty > 0 {
		bnk.SendCoins(self, royRecip, chain.Coins{chain.NewCoin("ugnot", royalty)})
	}
	if fee > 0 {
		bnk.SendCoins(self, feeRecipient, chain.Coins{chain.NewCoin("ugnot", fee)})
	}
	bnk.SendCoins(self, seller, chain.Coins{chain.NewCoin("ugnot", sellerAmt)}) // seller last

	chain.Emit("PurchaseConfirmed",
		"collection", collectionID,
		"tokenId", string(tid),
		"buyer", buyer.String(),
		"seller", seller.String(),
		"price", itoa(price),
		"fee", itoa(fee),
		"royalty", itoa(royalty),
		"royaltyRecipient", royRecip.String(),
		"sellerAmount", itoa(sellerAmt),
	)
}

// ── splitProceeds ─────────────────────────────────────────────────────────────

// splitProceeds computes the three-way split of a sale price.
// royaltyAmount comes pre-computed from nft.RoyaltyInfo (already the actual
// amount, not bps). We clamp it defensively against MaxRoyaltyBPS.
func splitProceeds(price, royaltyAmount int64) (fee, royalty, seller int64) {
	if price < MinPrice {
		panic("price below minimum")
	}
	if price > MaxPrice {
		panic("price above maximum")
	}
	fee = price * FeeBPS / 10000
	royalty = royaltyAmount
	if royalty < 0 {
		royalty = 0
	}
	maxRoy := price * MaxRoyaltyBPS / 10000
	if royalty > maxRoy {
		royalty = maxRoy // defense-in-depth clamp
	}
	if fee+royalty >= price {
		panic("fee plus royalty exceeds price")
	}
	seller = price - fee - royalty
	if seller <= 0 {
		panic("seller amount not positive")
	}
	return
}

// ── recordSale ────────────────────────────────────────────────────────────────

func recordSale(collectionID, tokenID string, seller, buyer address, price, fee, royalty int64) {
	nextSaleId++
	salesLog.Set(itoa(nextSaleId), &Sale{
		CollectionID: collectionID,
		TokenID:      tokenID,
		Seller:       seller,
		Buyer:        buyer,
		Price:        price,
		Fee:          fee,
		Royalty:      royalty,
		Blk:          runtime.ChainHeight(),
	})
}

// ── IsPaused ─────────────────────────────────────────────────────────────────

func IsPaused() bool { return paused }

// ── truncAddr / truncPath (render helpers) ────────────────────────────────────

func truncAddr(addr address) string {
	s := string(addr)
	if len(s) > 13 {
		return s[:10] + "..."
	}
	return s
}

func truncPath(path string) string {
	parts := strings.Split(path, "/")
	if len(parts) > 2 {
		return parts[len(parts)-1]
	}
	return path
}
