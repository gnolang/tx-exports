package gnomads_market

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"math"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd/gnomads"
)

const (
	marketDenom          = "ugnot"
	feeDenominator       = int64(10000)
	defaultProtocolFeeBps = int64(100) // 1%
	protocolFeeMaxBps     = int64(1000)
	maxListingPrice       = int64(math.MaxInt64 / protocolFeeMaxBps)
)

// Replace this local-development owner before Pearl or Mainnet deployment.
const localMarketAdmin address = "g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd"

type listing struct {
	seller            address
	price             int64
	expiresAt         int64
	nonce             int64
	royaltyReceiver   address
	royaltyAmount     int64
	protocolReceiver  address
	protocolFeeAmount int64
	sellerProceeds    int64
}

var (
	marketAddress      address
	listings           avl.Tree
	listingNonce       int64
	marketPaused       bool
	protocolFeeBps     = defaultProtocolFeeBps
	protocolTreasury   = localMarketAdmin
)

func init(cur realm) {
	marketAddress = cur.Address()
}

func Status() string { return "MARKETPLACE_READY" }

func Address() address { return marketAddress }

func CollectionID() string { return gnomads.CollectionID() }

func MarketPaused() bool { return marketPaused }

func ProtocolFeeBps() int64 { return protocolFeeBps }

func ProtocolTreasury() address { return protocolTreasury }

func ListingCount() int { return listings.Size() }

func HasListing(tokenID string) bool { return listings.Has(tokenID) }

func ListingSeller(tokenID string) address { return mustListing(tokenID).seller }

func ListingPrice(tokenID string) int64 { return mustListing(tokenID).price }

func ListingExpiry(tokenID string) int64 { return mustListing(tokenID).expiresAt }

func ListingNonce(tokenID string) int64 { return mustListing(tokenID).nonce }

func ListingRoyalty(tokenID string) (address, int64) {
	l := mustListing(tokenID)
	return l.royaltyReceiver, l.royaltyAmount
}

func ListingProtocolFee(tokenID string) (address, int64) {
	l := mustListing(tokenID)
	return l.protocolReceiver, l.protocolFeeAmount
}

func ListingSellerProceeds(tokenID string) int64 { return mustListing(tokenID).sellerProceeds }

// ConfigureProtocol affects new listings only. Existing listings retain the
// exact receiver and fee amounts shown when their seller created the order.
func ConfigureProtocol(cur realm, treasury address, feeBps int64) {
	assertMarketAdmin(cur.Previous().Address())
	if !treasury.IsValid() {
		panic("gnomads_market: invalid protocol treasury")
	}
	if feeBps < 0 || feeBps > protocolFeeMaxBps {
		panic("gnomads_market: protocol fee bps out of range")
	}
	protocolTreasury = treasury
	protocolFeeBps = feeBps
	chain.Emit(
		"ProtocolConfigured",
		"treasury", treasury.String(),
		"feeBps", ufmt.Sprintf("%d", feeBps),
	)
}

func SetMarketPaused(cur realm, paused bool) {
	assertMarketAdmin(cur.Previous().Address())
	marketPaused = paused
	chain.Emit("MarketPauseChanged", "paused", ufmt.Sprintf("%t", paused))
}

// List creates a non-custodial fixed-price order. The seller must first call
// Gnomads.SetApprovalForAll(Address(), true). Fee terms are snapshotted here.
func List(cur realm, tokenID string, price, expiresAt int64) {
	assertDirectUserCall(cur)
	if marketPaused {
		panic("gnomads_market: marketplace is paused")
	}
	if HasListing(tokenID) {
		panic("gnomads_market: token is already listed")
	}
	if price < 1 || price > maxListingPrice {
		panic("gnomads_market: invalid listing price")
	}
	if expiresAt != 0 && expiresAt <= time.Now().Unix() {
		panic("gnomads_market: listing expiry must be in the future")
	}

	seller := cur.Previous().Address()
	if gnomads.OwnerOf(tokenID) != seller {
		panic("gnomads_market: caller is not token owner")
	}
	if !gnomads.IsApprovedForAll(seller, Address()) {
		panic("gnomads_market: marketplace operator approval required")
	}

	royaltyReceiver, royaltyAmount := gnomads.RoyaltyInfo(tokenID, price)
	protocolAmount := calculateFee(price, protocolFeeBps)
	if royaltyAmount < 0 || royaltyAmount+protocolAmount > price {
		panic("gnomads_market: fees exceed listing price")
	}

	listingNonce++
	l := &listing{
		seller:            seller,
		price:             price,
		expiresAt:         expiresAt,
		nonce:             listingNonce,
		royaltyReceiver:   royaltyReceiver,
		royaltyAmount:     royaltyAmount,
		protocolReceiver:  protocolTreasury,
		protocolFeeAmount: protocolAmount,
		sellerProceeds:    price - royaltyAmount - protocolAmount,
	}
	listings.Set(tokenID, l)

	chain.Emit(
		"Listed",
		"tokenId", tokenID,
		"seller", seller.String(),
		"price", ufmt.Sprintf("%d", price),
		"expiresAt", ufmt.Sprintf("%d", expiresAt),
		"nonce", ufmt.Sprintf("%d", l.nonce),
	)
}

func Cancel(cur realm, tokenID string) {
	assertDirectUserCall(cur)
	l := mustListing(tokenID)
	if cur.Previous().Address() != l.seller {
		panic("gnomads_market: only seller can cancel listing")
	}
	listings.Remove(tokenID)
	chain.Emit("ListingCancelled", "tokenId", tokenID, "nonce", ufmt.Sprintf("%d", l.nonce))
}

// Invalidate removes an expired order, or an order whose owner/approval changed.
// Anyone may clear such an order because it can no longer settle as written.
func Invalidate(tokenID string) {
	l := mustListing(tokenID)
	if listingExecutable(tokenID, l) {
		panic("gnomads_market: listing is still executable")
	}
	listings.Remove(tokenID)
	chain.Emit("ListingInvalidated", "tokenId", tokenID, "nonce", ufmt.Sprintf("%d", l.nonce))
}

// Buy accepts only direct Adena/EOA calls so OriginSend describes coins that
// actually arrived at this realm. Transfer and all payouts roll back together.
func Buy(cur realm, tokenID string) {
	assertDirectUserCall(cur)
	if marketPaused {
		panic("gnomads_market: marketplace is paused")
	}
	l := mustListing(tokenID)
	if !listingExecutable(tokenID, l) {
		panic("gnomads_market: listing is stale or expired")
	}

	buyer := cur.Previous().Address()
	if buyer == l.seller {
		panic("gnomads_market: seller cannot buy own listing")
	}
	sent := unsafe.OriginSend()
	assertExactMarketPayment(sent, l.price)

	// Checks-effects-interactions: consume the one-time order before transfer and
	// payout. A panic still rolls the entire transaction back atomically.
	listings.Remove(tokenID)
	gnomads.MarketplaceTransfer(cross(cur), l.seller, buyer, tokenID, l.price, l.nonce)

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	pay(cur, b, l.seller, l.sellerProceeds)
	pay(cur, b, l.royaltyReceiver, l.royaltyAmount)
	pay(cur, b, l.protocolReceiver, l.protocolFeeAmount)

	chain.Emit(
		"Purchased",
		"tokenId", tokenID,
		"seller", l.seller.String(),
		"buyer", buyer.String(),
		"price", ufmt.Sprintf("%d", l.price),
		"royalty", ufmt.Sprintf("%d", l.royaltyAmount),
		"protocolFee", ufmt.Sprintf("%d", l.protocolFeeAmount),
		"sellerProceeds", ufmt.Sprintf("%d", l.sellerProceeds),
		"nonce", ufmt.Sprintf("%d", l.nonce),
	)
}

func Render(path string) string {
	if path != "" {
		return "404\n"
	}
	return "# Gnomads Marketplace\n\n" +
		ufmt.Sprintf("* **Collection**: %s\n", CollectionID()) +
		ufmt.Sprintf("* **Listings**: %d\n", ListingCount()) +
		ufmt.Sprintf("* **Protocol fee**: %d bps\n", ProtocolFeeBps()) +
		ufmt.Sprintf("* **Paused**: %t\n", MarketPaused())
}

func mustListing(tokenID string) *listing {
	v := listings.Get(tokenID)
	if v == nil {
		panic("gnomads_market: listing not found")
	}
	return v.(*listing)
}

func listingExecutable(tokenID string, l *listing) bool {
	if l.expiresAt != 0 && time.Now().Unix() >= l.expiresAt {
		return false
	}
	if gnomads.OwnerOf(tokenID) != l.seller {
		return false
	}
	return gnomads.IsApprovedForAll(l.seller, Address())
}

func calculateFee(price, bps int64) int64 {
	if price < 0 || bps < 0 || bps > protocolFeeMaxBps || (bps != 0 && price > math.MaxInt64/bps) {
		panic("gnomads_market: invalid fee calculation")
	}
	return price * bps / feeDenominator
}

func assertExactMarketPayment(sent chain.Coins, required int64) {
	if len(sent) != 1 || sent[0].Denom != marketDenom || sent[0].Amount != required {
		panic(ufmt.Sprintf("gnomads_market: exact payment required: %dugnot", required))
	}
}

func pay(cur realm, b banker.Banker, to address, amount int64) {
	if amount == 0 {
		return
	}
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin(marketDenom, amount)))
}

func assertDirectUserCall(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("gnomads_market: only direct user calls are accepted")
	}
}

func assertMarketAdmin(caller address) {
	if caller != localMarketAdmin {
		panic("gnomads_market: restricted access")
	}
}
