// Package nftoffers4 is the v2 escrowed offer/bid system for tokens
// minted through gno.land/r/g1hx4z2.../nft4.
//
// Where nftmarket2's List/Buy is seller-driven (owner sets a price, first
// buyer wins), offers are buyer-driven: anyone can escrow GNOT against a
// token — listed or not — and the owner may accept at their discretion.
//
// Escrow model: MakeOffer's --send amount lands in this realm's own
// balance and stays there until AcceptOffer pays it out (to the seller,
// minus royalty) or CancelOffer refunds it. The NFT itself is never
// escrowed — same non-custodial approval pattern as nftmarket2.
//
// WHAT CHANGED VS V1 (gno.land/r/g1hx4z2.../nftoffers)
//
//  1. cur.Previous().Address() instead of unsafe.OriginCaller() for
//     authorization, and assertDirectPayment on the one function that
//     accepts money. See nft4 / nftmarket2 package docs for why.
//
//  2. Offers expire. v1 offers were pending forever, so a buyer's GNOT
//     sat escrowed indefinitely unless they remembered to cancel, and an
//     owner could accept a months-stale bid made at a completely
//     different market price. v2 takes expiresInBlocks and refuses to
//     accept an expired offer (the buyer can always still cancel and get
//     a full refund, before or after expiry).
//
//  3. Collection-wide offers. Passing an empty tokenID bids on ANY token
//     in a collection, which is how someone actually shops ("I'll pay 5
//     GNOT for any piece from this drop") — v1 forced a separate offer
//     per token ID.
//
//  4. O(log n) lookups. v1's OffersForToken and OffersByBuyer scanned
//     every offer ever made on every call. v2 maintains token, buyer and
//     collection indexes.
//
//  5. AcceptOffer deactivates the offer BEFORE moving any coins (v1 did
//     it after the payout and the cross-realm transfer).
package nftoffers4

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft4"
)

// MaxExpiryBlocks caps how far in the future an offer may be set to
// expire, so "expiring" can't be used to mean "never" by accident.
// Pearl produces roughly one block per second, so this is about 30 days.
const MaxExpiryBlocks = 2_592_000

// Offer is one pending or historical bid. An empty tokenID means the
// offer applies to any token in the collection.
type Offer struct {
	id              string
	collectionID    string
	tokenID         string
	buyer           address
	amountUgnot     int64
	active          bool
	expiresAtHeight int64 // 0 = never expires
	createdAt       int64
}

// OfferInfo is the exported, read-only view of an Offer.
type OfferInfo struct {
	ID              string
	CollectionID    string
	TokenID         string
	Buyer           address
	AmountUgnot     int64
	Active          bool
	ExpiresAtHeight int64
	CreatedAt       int64
}

var (
	offers       = avl.NewTree() // offerID -> *Offer
	byToken      = avl.NewTree() // "collectionId:tokenId:paddedOfferID" -> offerID (active)
	byBuyer      = avl.NewTree() // "buyer:paddedOfferID" -> offerID (active)
	byCollection = avl.NewTree() // "collectionId:paddedOfferID" -> offerID (active, collection-wide only)
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

// MakeOffer escrows the transaction's --send amount as an offer on
// collectionID:tokenID. Pass an empty tokenID to bid on any token in the
// collection. expiresInBlocks may be 0 for an offer that never expires.
func MakeOffer(cur realm, collectionID, tokenID string, expiresInBlocks int64) string {
	assertDirectPayment(cur)
	caller := cur.Previous().Address()

	amt := unsafe.OriginSend().AmountOf("ugnot")
	if amt <= 0 {
		panic("offer must send a positive ugnot amount")
	}
	if expiresInBlocks < 0 || expiresInBlocks > MaxExpiryBlocks {
		panic("expiresInBlocks must be between 0 (never) and " +
			strconv.FormatInt(MaxExpiryBlocks, 10))
	}

	// Collection must exist either way; for a token-specific offer the
	// token must exist too and must not already belong to the bidder.
	nft4.GetCollection(collectionID)
	if tokenID != "" {
		owner, err := nft4.OwnerOf(collectionID, tokenID)
		if err != nil {
			panic(err)
		}
		if owner == caller {
			panic("cannot make an offer on your own token")
		}
	}

	var expiresAt int64
	if expiresInBlocks > 0 {
		expiresAt = runtime.ChainHeight() + expiresInBlocks
	}

	nextID++
	id := strconv.FormatInt(nextID, 10)
	o := &Offer{
		id:              id,
		collectionID:    collectionID,
		tokenID:         tokenID,
		buyer:           caller,
		amountUgnot:     amt,
		active:          true,
		expiresAtHeight: expiresAt,
		createdAt:       runtime.ChainHeight(),
	}
	offers.Set(id, o)
	indexActive(o)

	chain.Emit(
		"OfferMade",
		"offerId", id,
		"collection", collectionID,
		"tokenId", tokenID,
		"buyer", caller.String(),
		"amount", strconv.FormatInt(amt, 10),
		"expiresAtHeight", strconv.FormatInt(expiresAt, 10),
	)

	return id
}

// CancelOffer withdraws a pending offer and refunds the escrow to the
// buyer. Buyer only; allowed before or after expiry.
func CancelOffer(cur realm, offerID string) {
	caller := cur.Previous().Address()
	o := mustGetOffer(offerID)
	if !o.active {
		panic("offer is not active")
	}
	if o.buyer != caller {
		panic("only the offer's buyer can cancel it")
	}

	deactivate(o)

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), o.buyer, chain.NewCoins(chain.NewCoin("ugnot", o.amountUgnot)))

	chain.Emit("OfferCancelled", "offerId", offerID)
}

// AcceptOffer sells a token to the offer's buyer at the escrowed price.
// Only the token's current owner may accept, and this realm must already
// be approved on nft4. tokenID selects which token to sell for a
// collection-wide offer; for a token-specific offer it must match (pass
// an empty string to use the offer's own token).
func AcceptOffer(cur realm, offerID, tokenID string) {
	caller := cur.Previous().Address()
	o := mustGetOffer(offerID)
	if !o.active {
		panic("offer is not active")
	}
	if o.expiresAtHeight > 0 && runtime.ChainHeight() > o.expiresAtHeight {
		panic("offer has expired")
	}

	sellTokenID := resolveToken(o, tokenID)

	owner, err := nft4.OwnerOf(o.collectionID, sellTokenID)
	if err != nil {
		panic(err)
	}
	if owner != caller {
		panic("only the current token owner can accept this offer")
	}
	if o.buyer == caller {
		panic("cannot accept your own offer")
	}

	realmAddr := cur.Address()
	approved, _ := nft4.GetApproved(o.collectionID, sellTokenID)
	if approved != realmAddr && !nft4.IsApprovedForAll(o.collectionID, owner, realmAddr) {
		panic("nftoffers4 is not approved to transfer this token yet; call nft4.Approve or nft4.SetApprovalForAll first")
	}

	// Deactivate before any coins move.
	deactivate(o)

	royaltyAddr, rawRoyalty, err := nft4.RoyaltyInfo(o.collectionID, sellTokenID, o.amountUgnot)
	if err != nil {
		rawRoyalty = 0
	}
	royaltyAmt, sellerAmt := splitPayment(o.amountUgnot, rawRoyalty, royaltyAddr == owner)

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if royaltyAmt > 0 {
		bk.SendCoins(realmAddr, royaltyAddr, chain.NewCoins(chain.NewCoin("ugnot", royaltyAmt)))
	}
	bk.SendCoins(realmAddr, owner, chain.NewCoins(chain.NewCoin("ugnot", sellerAmt)))

	// Reverts the whole tx, coin transfers included, if the approval no
	// longer stands.
	nft4.TransferFrom(cross(cur), o.collectionID, sellTokenID, owner, o.buyer)

	chain.Emit(
		"OfferAccepted",
		"offerId", offerID,
		"collection", o.collectionID,
		"tokenId", sellTokenID,
		"seller", owner.String(),
		"buyer", o.buyer.String(),
		"amount", strconv.FormatInt(o.amountUgnot, 10),
		"royalty", strconv.FormatInt(royaltyAmt, 10),
	)
}

// splitPayment is the pure payout arithmetic, unit-testable without a
// funded chain.
func splitPayment(amount, royalty int64, royaltyGoesToSeller bool) (royaltyAmt, sellerAmt int64) {
	if royalty <= 0 || royalty >= amount || royaltyGoesToSeller {
		royalty = 0
	}
	return royalty, amount - royalty
}

// Read-only views.

// GetOffer returns one offer by ID.
func GetOffer(offerID string) OfferInfo {
	return toInfo(mustGetOffer(offerID))
}

// OffersForToken returns active, unexpired offers that can be accepted
// for one token: both token-specific offers and collection-wide ones.
func OffersForToken(collectionID, tokenID string) []OfferInfo {
	out := collect(byToken, collectionID+":"+tokenID+":", collectionID+":"+tokenID+";", 0, 0)
	return append(out, collect(byCollection, collectionID+":", collectionID+";", 0, 0)...)
}

// OffersByBuyer returns a page of one buyer's active offers.
func OffersByBuyer(buyer address, offset, limit int64) []OfferInfo {
	return collect(byBuyer, buyer.String()+":", buyer.String()+";", offset, limit)
}

// CollectionOffers returns active collection-wide offers for one
// collection, i.e. bids any holder in that collection could accept.
func CollectionOffers(collectionID string, offset, limit int64) []OfferInfo {
	return collect(byCollection, collectionID+":", collectionID+";", offset, limit)
}

// BestOfferForToken returns the highest active, unexpired offer amount a
// holder could accept for a token (0 if there is none).
func BestOfferForToken(collectionID, tokenID string) int64 {
	var best int64
	for _, o := range OffersForToken(collectionID, tokenID) {
		if o.AmountUgnot > best {
			best = o.AmountUgnot
		}
	}
	return best
}

// OfferCount returns the total number of offers ever created.
func OfferCount() int64 { return nextID }

// ActiveOfferCount returns how many offers are currently active,
// including expired-but-not-yet-cancelled ones.
func ActiveOfferCount() int64 { return activeCount }

// Render implements the gno.land realm home-page convention.
func Render(path string) string {
	if path != "" {
		o, ok := offers.Get(path).(*Offer)
		if !ok {
			return "# 404\n\noffer not found: " + path
		}
		return renderOffer(o)
	}

	out := "# gnoNFT Offers v2\n\n"
	if activeCount == 0 {
		return out + "No active offers.\n"
	}
	out += strconv.FormatInt(activeCount, 10) + " active offer(s)\n\n"
	offers.Iterate("", "", func(key string, value any) bool {
		if o := value.(*Offer); o.active {
			out += renderOffer(o) + "\n"
		}
		return false
	})
	return out
}

func renderOffer(o *Offer) string {
	target := o.collectionID + ":" + o.tokenID
	if o.tokenID == "" {
		target = "collection " + o.collectionID + " (any token)"
	}
	status := "active"
	if !o.active {
		status = "resolved"
	} else if o.expiresAtHeight > 0 && runtime.ChainHeight() > o.expiresAtHeight {
		status = "expired"
	}
	return "- #" + o.id + " " + target +
		" - " + strconv.FormatInt(o.amountUgnot, 10) + "ugnot - buyer " + o.buyer.String() +
		" (" + status + ")"
}

// Internal helpers.

// resolveToken decides which token an accept applies to: a
// token-specific offer is pinned to its own token, while a
// collection-wide offer requires the accepting owner to name one.
func resolveToken(o *Offer, tokenID string) string {
	if o.tokenID != "" {
		if tokenID != "" && tokenID != o.tokenID {
			panic("this offer is for token " + o.tokenID + ", not " + tokenID)
		}
		return o.tokenID
	}
	if tokenID == "" {
		panic("this is a collection-wide offer: pass the token ID you want to sell")
	}
	return tokenID
}

func indexActive(o *Offer) {
	p := padID(o.id)
	byBuyer.Set(o.buyer.String()+":"+p, o.id)
	if o.tokenID == "" {
		byCollection.Set(o.collectionID+":"+p, o.id)
	} else {
		byToken.Set(o.collectionID+":"+o.tokenID+":"+p, o.id)
	}
	activeCount++
}

func deactivate(o *Offer) {
	o.active = false
	p := padID(o.id)
	byBuyer.Remove(o.buyer.String() + ":" + p)
	if o.tokenID == "" {
		byCollection.Remove(o.collectionID + ":" + p)
	} else {
		byToken.Remove(o.collectionID + ":" + o.tokenID + ":" + p)
	}
	if activeCount > 0 {
		activeCount--
	}
}

// collect pages over an index tree, skipping offers that are inactive or
// already past their expiry height (an expired offer is not acceptable, so
// showing it as available would be misleading).
func collect(tree *avl.Tree, start, end string, offset, limit int64) []OfferInfo {
	var out []OfferInfo
	var seen int64
	h := runtime.ChainHeight()
	tree.Iterate(start, end, func(key string, value any) bool {
		o, ok := offers.Get(value.(string)).(*Offer)
		if !ok || !o.active {
			return false
		}
		if o.expiresAtHeight > 0 && h > o.expiresAtHeight {
			return false
		}
		if seen < offset {
			seen++
			return false
		}
		if limit > 0 && int64(len(out)) >= limit {
			return true
		}
		out = append(out, toInfo(o))
		seen++
		return false
	})
	return out
}

func padID(id string) string {
	const width = 12
	if len(id) >= width {
		return id
	}
	return "000000000000"[:width-len(id)] + id
}

func toInfo(o *Offer) OfferInfo {
	return OfferInfo{
		ID:              o.id,
		CollectionID:    o.collectionID,
		TokenID:         o.tokenID,
		Buyer:           o.buyer,
		AmountUgnot:     o.amountUgnot,
		Active:          o.active,
		ExpiresAtHeight: o.expiresAtHeight,
		CreatedAt:       o.createdAt,
	}
}

func mustGetOffer(id string) *Offer {
	v := offers.Get(id)
	if v == nil {
		panic("offer not found: " + id)
	}
	return v.(*Offer)
}
