// Package nftmarket56 is the v5 non-custodial GNOT marketplace for
// collections minted through gno.land/r/g1hx4z2.../nft56.
//
// Behaviour is identical to nftmarket4 (same functions, same events, same
// non-custodial approval model). What changed is what a sale record costs
// to keep on chain.
//
// WHAT CHANGED VS V4 (gno.land/r/g1hx4z2.../nftmarket4)
//
//  1. Records are roughly half the size. v4 stored every numeric field as
//     a string ("1", "12", "5000000") inside the Listing itself AND wrote
//     the listing ID as a string into four index trees. Measured on
//     pearl-1, one listing wrote about 8 KB, i.e. ~0.8 GNOT of storage
//     deposit per List call. v5 keeps ids, collection ids, token ids and
//     prices as int64 internally and stores int64 values in the indexes,
//     so the same listing costs materially less to open. The exported
//     ListingInfo still speaks strings, so the frontend decoder is
//     unchanged - only the pkgpath in config/gno.ts moves.
//
//  2. It points at nft56, whose generative tokens render from a seed.
//     Nothing here has to know that: TokenURI resolution happens inside
//     nft56.
//
//  3. ONE index instead of four. v5.5 wrote listings + byToken +
//     activeIndex + bySeller + byCollection on every List - five AVL
//     nodes - and removed four of them on every Cancel/Buy. The last
//     three held nothing that byToken did not already reach, and byToken
//     is active-only (deactivate removes it), so seller/collection/active
//     pagination is now a filtered walk over byToken instead of three
//     duplicated trees. Listing a token costs two writes, not five.
//
//     This is deliberately NOT a move to an off-chain indexer: every
//     query still answers from chain state, so the marketplace keeps
//     working if the indexer is down. The price paid is that
//     ListBySeller scans the active book (bounded by the number of live
//     listings, not by history) and results are ordered by
//     collection:token rather than by listing id.
//
// Everything v4 already got right is kept deliberately: authorization via
// cur.Previous().Address(), assertDirectPayment on the one function that
// takes money, deactivate-before-payout ordering, and real active-only
// pagination indexes.
package nftmarket56

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft56"
)

// Listing is one active or historical sale offer. Every numeric field is
// an int64 on purpose - see the package doc, change #1.
type Listing struct {
	id           int64
	collectionID int64
	tokenID      int64
	seller       address
	priceUgnot   int64
	active       bool
	createdAt    int64
}

// ListingInfo is the exported, read-only view of a Listing. IDs stay
// strings here so existing frontend decoders keep working untouched.
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
	listings = avl.NewTree() // paddedListingID -> *Listing (active and closed)
	// byToken is the ONLY live index: "collectionId:tokenId" -> int64
	// listing id, holding active listings exclusively (deactivate removes
	// the entry). It is simultaneously the duplicate-listing guard, the
	// per-token lookup, and the universe every paginated read walks.
	byToken     = avl.NewTree()
	nextID      int64
	activeCount int64
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
// address on nft56 beforehand.
func List(cur realm, collectionID, tokenID string, priceUgnot int64) string {
	caller := cur.Previous().Address()
	if priceUgnot <= 0 {
		panic("price must be positive")
	}
	cid := parseID(collectionID, "collection id")
	tid := parseID(tokenID, "token id")

	owner, err := nft56.OwnerOf(collectionID, tokenID)
	if err != nil {
		panic(err)
	}
	if owner != caller {
		panic("only the token owner can list it")
	}
	assertApproved(cur, collectionID, tokenID, owner)

	key := collectionID + ":" + tokenID
	if listingID, ok := avlGet(byToken, key).(int64); ok {
		if l := getListing(listingID); l != nil && l.active {
			panic("token is already listed (listing #" + strconv.FormatInt(listingID, 10) + ")")
		}
	}

	nextID++
	l := &Listing{
		id:           nextID,
		collectionID: cid,
		tokenID:      tid,
		seller:       caller,
		priceUgnot:   priceUgnot,
		active:       true,
		createdAt:    runtime.ChainHeight(),
	}
	listings.Set(padID(l.id), l)
	byToken.Set(key, l.id)
	indexActive(l)

	id := strconv.FormatInt(l.id, 10)
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

	collectionID := strconv.FormatInt(l.collectionID, 10)
	tokenID := strconv.FormatInt(l.tokenID, 10)

	// Deactivate first, then move money.
	deactivate(l)

	royaltyAddr, rawRoyalty, err := nft56.RoyaltyInfo(collectionID, tokenID, l.priceUgnot)
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

	// Cross into nft56 to move ownership. This reverts the whole tx,
	// including the transfers above, if the seller's approval no longer
	// stands or they no longer own the token.
	nft56.TransferFrom(cross(cur), collectionID, tokenID, l.seller, caller)

	chain.Emit(
		"NFTSold",
		"listingId", listingID,
		"collection", collectionID,
		"tokenId", tokenID,
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

// ListActive returns exactly one page of ACTIVE listings, ordered by
// collection then token (v5.6: see the package doc, change #3 - v5.5
// ordered by listing id).
func ListActive(offset, limit int64) []ListingInfo {
	return pageActive("", "", nil, offset, limit)
}

// ListBySeller returns a page of one seller's active listings. This walks
// the active book and filters, so its cost tracks the number of LIVE
// listings rather than the number of listings ever created.
func ListBySeller(seller address, offset, limit int64) []ListingInfo {
	return pageActive("", "", func(l *Listing) bool { return l.seller == seller }, offset, limit)
}

// ListByCollection returns a page of one collection's active listings.
// byToken is keyed "collectionId:tokenId", so this is a true prefix range:
// collection 1 cannot leak listings from collection 11.
func ListByCollection(collectionID string, offset, limit int64) []ListingInfo {
	return pageActive(collectionID+":", collectionID+";", nil, offset, limit)
}

// ListingForToken returns the active listing on a token, or an empty
// ListingInfo if there is none - one lookup instead of scanning pages.
func ListingForToken(collectionID, tokenID string) ListingInfo {
	if id, ok := avlGet(byToken, collectionID + ":" + tokenID).(int64); ok {
		if l := getListing(id); l != nil && l.active {
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
// (0 when it has no active listings).
func FloorPrice(collectionID string) int64 {
	var floor int64
	byToken.Iterate(collectionID+":", collectionID+";", func(key string, value any) bool {
		if l := getListing(value.(int64)); l != nil && l.active {
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
		l := getListingByString(path)
		if l == nil {
			return "# 404\n\nlisting not found: " + path
		}
		return renderListing(l)
	}

	out := "# gnoNFT Marketplace v5\n\n"
	if activeCount == 0 {
		return out + "No active listings.\n"
	}
	out += strconv.FormatInt(activeCount, 10) + " active listing(s)\n\n"
	byToken.Iterate("", "", func(key string, value any) bool {
		if l := getListing(value.(int64)); l != nil {
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
	return "- #" + strconv.FormatInt(l.id, 10) + " " +
		strconv.FormatInt(l.collectionID, 10) + ":" + strconv.FormatInt(l.tokenID, 10) +
		" - " + strconv.FormatInt(l.priceUgnot, 10) + "ugnot - seller " + l.seller.String() +
		" (" + status + ")"
}

// Internal helpers.

func assertApproved(cur realm, collectionID, tokenID string, owner address) {
	marketAddr := cur.Address()
	approved, _ := nft56.GetApproved(collectionID, tokenID)
	if approved != marketAddr && !nft56.IsApprovedForAll(collectionID, owner, marketAddr) {
		panic("marketplace is not approved to transfer this token yet; call nft56.Approve or nft56.SetApprovalForAll first")
	}
}

// indexActive records that a listing is live. The byToken entry is written
// by List itself (it doubles as the already-listed guard), so all that is
// left here is the counter - which is a plain int64 field, not an AVL node.
func indexActive(l *Listing) {
	activeCount++
}

func deactivate(l *Listing) {
	l.active = false
	// Dropping the byToken entry is what frees the token to be relisted and
	// what removes the listing from every paginated read at once.
	byToken.Remove(strconv.FormatInt(l.collectionID, 10) + ":" + strconv.FormatInt(l.tokenID, 10))
	if activeCount > 0 {
		activeCount--
	}
}

// pageActive walks the active book (byToken) over an optional key range,
// applies an optional predicate, and returns one page. Offset counts only
// rows that actually matched, so paging through a filtered view can never
// skip results the way offsetting over a pre-filtered tree could.
func pageActive(start, end string, keep func(*Listing) bool, offset, limit int64) []ListingInfo {
	if offset < 0 {
		offset = 0
	}
	if limit < 0 {
		limit = 0
	}
	out := make([]ListingInfo, 0, limit)
	var seen int64
	byToken.Iterate(start, end, func(key string, value any) bool {
		l := getListing(value.(int64))
		if l == nil || !l.active {
			return false
		}
		if keep != nil && !keep(l) {
			return false
		}
		if seen < offset {
			seen++
			return false
		}
		if limit > 0 && int64(len(out)) >= limit {
			return true
		}
		out = append(out, toInfo(l))
		seen++
		return false
	})
	return out
}

// padID zero-pads a numeric ID so index trees sort numerically rather
// than lexicographically ("10" must come after "2").
func padID(id int64) string {
	const width = 12
	s := strconv.FormatInt(id, 10)
	if len(s) >= width {
		return s
	}
	return "000000000000"[:width-len(s)] + s
}

// parseID rejects anything that is not a positive decimal integer, so a
// malformed id can never be written into a record or an index key.
func parseID(s, what string) int64 {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v <= 0 {
		panic("invalid " + what + ": " + s)
	}
	return v
}

func toInfo(l *Listing) ListingInfo {
	return ListingInfo{
		ID:           strconv.FormatInt(l.id, 10),
		CollectionID: strconv.FormatInt(l.collectionID, 10),
		TokenID:      strconv.FormatInt(l.tokenID, 10),
		Seller:       l.seller,
		PriceUgnot:   l.priceUgnot,
		Active:       l.active,
		CreatedAt:    l.createdAt,
	}
}

func getListing(id int64) *Listing {
	v := avlGet(listings, padID(id))
	if v == nil {
		return nil
	}
	return v.(*Listing)
}

func getListingByString(id string) *Listing {
	v, err := strconv.ParseInt(id, 10, 64)
	if err != nil {
		return nil
	}
	return getListing(v)
}

func mustGetListing(id string) *Listing {
	l := getListingByString(id)
	if l == nil {
		panic("listing not found: " + id)
	}
	return l
}
