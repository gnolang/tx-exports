// Package nftmarket4 is the v2 non-custodial GNOT marketplace for
// collections minted through gno.land/r/g1hx4z2.../nft4.
//
// Non-custodial: listing a token never moves it into this realm. The
// seller approves this realm's address as an operator on nft4, and List
// only records the intent to sell. At Buy time this realm cross-calls
// nft4.TransferFrom on the seller's behalf, which only succeeds while the
// approval still stands — so a seller can invalidate every open listing at
// once by transferring the token or revoking the approval.
//
// WHAT CHANGED VS V1 (gno.land/r/g1hx4z2.../nftmarket)
//
//  1. Authorization uses cur.Previous().Address() instead of
//     unsafe.OriginCaller(). See nft4's package doc for the full
//     reasoning; in short, OriginCaller is gno's tx.origin and lets any
//     realm the user calls act as that user.
//
//  2. Payment verification is hardened. v1 read unsafe.OriginSend() with
//     no guard on how it was reached. The tx's --send envelope is
//     credited to whichever realm the tx calls *directly*, but
//     OriginSend() reports it to every realm in the call chain — so a
//     malicious realm could take the user's coins itself, then cross-call
//     Buy, which would see a funded envelope it never received and pay
//     the seller out of the marketplace's own balance. gno.land's stdlib
//     prescribes exactly one remedy for this ("pair with
//     cur.Previous().IsUserCall()"), which
//     assertDirectPayment below implements.
//
//  3. A listing is deactivated BEFORE any coins move. v1 flipped
//     active=false after the payouts and the cross-realm transfer, which
//     left a window where re-entrant code could observe a still-active,
//     already-paid listing.
//
//  4. Real pagination and indexes. v1's ListActive paged over ALL
//     listings and filtered afterwards, so a page could come back empty
//     while active listings existed further along. v2 keeps a dedicated
//     active-listing tree plus seller and collection indexes, so the
//     frontend no longer has to fetch everything and filter client-side.
//
//  5. UpdatePrice, so re-pricing no longer needs cancel + re-list (two
//     transactions, two gas fees, and a gap where someone else can list).
package nftmarket4

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft4"
)

// Listing is one active or historical sale offer.
type Listing struct {
	id           string
	collectionID string
	tokenID      string
	seller       address
	priceUgnot   int64
	active       bool
	createdAt    int64
}

// ListingInfo is the exported, read-only view of a Listing.
type ListingInfo struct {
	ID           string
	CollectionID string
	TokenID      string
	Seller       address
	PriceUgnot   int64
	Active       bool
	CreatedAt    int64
}

var (
	listings     = avl.NewTree() // listingID -> *Listing
	activeIndex  = avl.NewTree() // paddedListingID -> listingID (active only)
	byToken      = avl.NewTree() // "collectionId:tokenId" -> listingID (one active listing per token)
	bySeller     = avl.NewTree() // "seller:paddedListingID" -> listingID (active only)
	byCollection = avl.NewTree() // "collectionId:paddedListingID" -> listingID (active only)
	nextID       int64
	activeCount  int64
)

// assertDirectPayment rejects any call path where the tx's coin envelope
// cannot be trusted to have actually landed in this realm.
//
// IsUserCall() is true only when the previous frame is an EOA calling this
// function directly ("gnokey maketx call" / a wallet): its pkgPath is empty.
// Every code realm has a non-empty pkgPath, and MsgRun executes inside the
// ephemeral /e/<addr>/run realm, so both paths are rejected here.
//
// runtime.AssertOriginCall() is deliberately NOT used. Under the crossing
// model a "cur realm" function is always entered one frame below the message
// call itself, so the assert can never pass - not even for a legitimate
// direct wallet call. Verified on pearl-1: it aborted a real Buy tx with
// "invalid non-origin call".
func assertDirectPayment(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("this function must be called directly by a wallet, not through another realm")
	}
}

// List offers a token for sale at priceUgnot (1 GNOT = 1_000_000 ugnot).
// The caller must own the token and must have approved this realm's
// address on nft4 beforehand.
func List(cur realm, collectionID, tokenID string, priceUgnot int64) string {
	caller := cur.Previous().Address()
	if priceUgnot <= 0 {
		panic("price must be positive")
	}

	owner, err := nft4.OwnerOf(collectionID, tokenID)
	if err != nil {
		panic(err)
	}
	if owner != caller {
		panic("only the token owner can list it")
	}
	assertApproved(cur, collectionID, tokenID, owner)

	key := collectionID + ":" + tokenID
	if listingID, ok := byToken.Get(key).(string); ok {
		if l, ok2 := listings.Get(listingID).(*Listing); ok2 && l.active {
			panic("token is already listed (listing #" + listingID + ")")
		}
	}

	nextID++
	id := strconv.FormatInt(nextID, 10)
	l := &Listing{
		id:           id,
		collectionID: collectionID,
		tokenID:      tokenID,
		seller:       caller,
		priceUgnot:   priceUgnot,
		active:       true,
		createdAt:    runtime.ChainHeight(),
	}
	listings.Set(id, l)
	byToken.Set(key, id)
	indexActive(l)

	chain.Emit(
		"NFTListed",
		"listingId", id,
		"collection", collectionID,
		"tokenId", tokenID,
		"seller", caller.String(),
		"price", strconv.FormatInt(priceUgnot, 10),
	)

	return id
}

// UpdatePrice re-prices an active listing in place. Seller only.
func UpdatePrice(cur realm, listingID string, priceUgnot int64) {
	caller := cur.Previous().Address()
	l := mustGetListing(listingID)
	if !l.active {
		panic("listing is not active")
	}
	if l.seller != caller {
		panic("only the seller can change this listing's price")
	}
	if priceUgnot <= 0 {
		panic("price must be positive")
	}
	old := l.priceUgnot
	l.priceUgnot = priceUgnot

	chain.Emit(
		"NFTListingRepriced",
		"listingId", listingID,
		"oldPrice", strconv.FormatInt(old, 10),
		"price", strconv.FormatInt(priceUgnot, 10),
	)
}

// Cancel withdraws an active listing. Seller only.
func Cancel(cur realm, listingID string) {
	caller := cur.Previous().Address()
	l := mustGetListing(listingID)
	if !l.active {
		panic("listing is not active")
	}
	if l.seller != caller {
		panic("only the seller can cancel this listing")
	}

	deactivate(l)
	chain.Emit("NFTListingCancelled", "listingId", listingID)
}

// Buy purchases an active listing. The transaction must send at least the
// listing's priceUgnot; any excess is refunded. Royalties declared on the
// token are paid to the collection creator before the seller is paid.
func Buy(cur realm, listingID string) {
	assertDirectPayment(cur)
	caller := cur.Previous().Address()

	l := mustGetListing(listingID)
	if !l.active {
		panic("listing is not active")
	}
	if l.seller == caller {
		panic("cannot buy your own listing")
	}

	sentAmt := unsafe.OriginSend().AmountOf("ugnot")
	if sentAmt < l.priceUgnot {
		panic("insufficient payment: sent " + strconv.FormatInt(sentAmt, 10) +
			"ugnot, need " + strconv.FormatInt(l.priceUgnot, 10) + "ugnot")
	}

	// Deactivate first, then move money (see package doc, change #3).
	deactivate(l)

	royaltyAddr, rawRoyalty, err := nft4.RoyaltyInfo(l.collectionID, l.tokenID, l.priceUgnot)
	if err != nil {
		rawRoyalty = 0
	}
	royaltyAmt, sellerAmt, refund := splitPayment(l.priceUgnot, sentAmt, rawRoyalty, royaltyAddr == l.seller)

	marketAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if royaltyAmt > 0 {
		bk.SendCoins(marketAddr, royaltyAddr, chain.NewCoins(chain.NewCoin("ugnot", royaltyAmt)))
	}
	bk.SendCoins(marketAddr, l.seller, chain.NewCoins(chain.NewCoin("ugnot", sellerAmt)))
	if refund > 0 {
		bk.SendCoins(marketAddr, caller, chain.NewCoins(chain.NewCoin("ugnot", refund)))
	}

	// Cross into nft4 to move ownership. This reverts the whole tx,
	// including the transfers above, if the seller's approval no longer
	// stands or they no longer own the token.
	nft4.TransferFrom(cross(cur), l.collectionID, l.tokenID, l.seller, caller)

	chain.Emit(
		"NFTSold",
		"listingId", listingID,
		"collection", l.collectionID,
		"tokenId", l.tokenID,
		"seller", l.seller.String(),
		"buyer", caller.String(),
		"price", strconv.FormatInt(l.priceUgnot, 10),
		"royalty", strconv.FormatInt(royaltyAmt, 10),
	)
}

// splitPayment is the pure payout arithmetic, kept separate so it can be
// unit-tested without a funded chain: a royalty is only honoured when it
// is positive, strictly smaller than the price, and not payable to the
// seller themselves (in which case paying it would just be a needless
// extra transfer of the seller's own money).
func splitPayment(price, sent, royalty int64, royaltyGoesToSeller bool) (royaltyAmt, sellerAmt, refund int64) {
	if royalty <= 0 || royalty >= price || royaltyGoesToSeller {
		royalty = 0
	}
	refund = sent - price
	if refund < 0 {
		refund = 0
	}
	return royalty, price - royalty, refund
}

// Read-only views.

// GetListing returns one listing by ID.
func GetListing(listingID string) ListingInfo {
	return toInfo(mustGetListing(listingID))
}

// ListActive returns exactly one page of ACTIVE listings, oldest first.
// Unlike v1, offset/limit apply to the active set only.
func ListActive(offset, limit int64) []ListingInfo {
	return page(activeIndex, "", "", offset, limit)
}

// ListBySeller returns a page of one seller's active listings.
func ListBySeller(seller address, offset, limit int64) []ListingInfo {
	return page(bySeller, seller.String()+":", seller.String()+";", offset, limit)
}

// ListByCollection returns a page of one collection's active listings.
func ListByCollection(collectionID string, offset, limit int64) []ListingInfo {
	return page(byCollection, collectionID+":", collectionID+";", offset, limit)
}

// ListingForToken returns the active listing on a token, or an empty
// ListingInfo if there is none — one lookup instead of scanning pages.
func ListingForToken(collectionID, tokenID string) ListingInfo {
	if id, ok := byToken.Get(collectionID + ":" + tokenID).(string); ok {
		if l, ok2 := listings.Get(id).(*Listing); ok2 && l.active {
			return toInfo(l)
		}
	}
	return ListingInfo{}
}

// ListingCount returns the total number of listings ever created.
func ListingCount() int64 { return nextID }

// ActiveListingCount returns how many listings are currently active, so a
// UI can page without over-fetching.
func ActiveListingCount() int64 { return activeCount }

// FloorPrice returns the lowest active asking price across a collection
// (0 when it has no active listings). Computed on-chain so the frontend
// stops deriving a "floor" from whatever subset it happened to load.
func FloorPrice(collectionID string) int64 {
	var floor int64
	byCollection.Iterate(collectionID+":", collectionID+";", func(key string, value any) bool {
		if l, ok := listings.Get(value.(string)).(*Listing); ok && l.active {
			if floor == 0 || l.priceUgnot < floor {
				floor = l.priceUgnot
			}
		}
		return false
	})
	return floor
}

// Render implements the gno.land realm home-page convention.
func Render(path string) string {
	if path != "" {
		l, ok := listings.Get(path).(*Listing)
		if !ok {
			return "# 404\n\nlisting not found: " + path
		}
		return renderListing(l)
	}

	out := "# gnoNFT Marketplace v2\n\n"
	if activeCount == 0 {
		return out + "No active listings.\n"
	}
	out += strconv.FormatInt(activeCount, 10) + " active listing(s)\n\n"
	activeIndex.Iterate("", "", func(key string, value any) bool {
		if l, ok := listings.Get(value.(string)).(*Listing); ok {
			out += renderListing(l) + "\n"
		}
		return false
	})
	return out
}

func renderListing(l *Listing) string {
	status := "active"
	if !l.active {
		status = "sold/cancelled"
	}
	return "- #" + l.id + " " + l.collectionID + ":" + l.tokenID +
		" - " + strconv.FormatInt(l.priceUgnot, 10) + "ugnot - seller " + l.seller.String() +
		" (" + status + ")"
}

// Internal helpers.

func assertApproved(cur realm, collectionID, tokenID string, owner address) {
	marketAddr := cur.Address()
	approved, _ := nft4.GetApproved(collectionID, tokenID)
	if approved != marketAddr && !nft4.IsApprovedForAll(collectionID, owner, marketAddr) {
		panic("marketplace is not approved to transfer this token yet; call nft4.Approve or nft4.SetApprovalForAll first")
	}
}

func indexActive(l *Listing) {
	p := padID(l.id)
	activeIndex.Set(p, l.id)
	bySeller.Set(l.seller.String()+":"+p, l.id)
	byCollection.Set(l.collectionID+":"+p, l.id)
	activeCount++
}

func deactivate(l *Listing) {
	l.active = false
	p := padID(l.id)
	activeIndex.Remove(p)
	bySeller.Remove(l.seller.String() + ":" + p)
	byCollection.Remove(l.collectionID + ":" + p)
	byToken.Remove(l.collectionID + ":" + l.tokenID)
	if activeCount > 0 {
		activeCount--
	}
}

func page(tree *avl.Tree, start, end string, offset, limit int64) []ListingInfo {
	out := make([]ListingInfo, 0, limit)
	var seen int64
	tree.Iterate(start, end, func(key string, value any) bool {
		if seen < offset {
			seen++
			return false
		}
		if limit > 0 && int64(len(out)) >= limit {
			return true
		}
		if l, ok := listings.Get(value.(string)).(*Listing); ok && l.active {
			out = append(out, toInfo(l))
		}
		seen++
		return false
	})
	return out
}

// padID zero-pads a numeric ID so index trees sort numerically rather
// than lexicographically ("10" must come after "2").
func padID(id string) string {
	const width = 12
	if len(id) >= width {
		return id
	}
	return "000000000000"[:width-len(id)] + id
}

func toInfo(l *Listing) ListingInfo {
	return ListingInfo{
		ID:           l.id,
		CollectionID: l.collectionID,
		TokenID:      l.tokenID,
		Seller:       l.seller,
		PriceUgnot:   l.priceUgnot,
		Active:       l.active,
		CreatedAt:    l.createdAt,
	}
}

func mustGetListing(id string) *Listing {
	v := listings.Get(id)
	if v == nil {
		panic("listing not found: " + id)
	}
	return v.(*Listing)
}
