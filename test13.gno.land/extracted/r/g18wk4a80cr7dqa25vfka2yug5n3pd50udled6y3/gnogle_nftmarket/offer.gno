package gnogle_nftmarket

import (
	"chain"
	"strconv"

	"gno.land/p/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/grc721"
	"gno.land/p/nt/avl/v0"
)

// Offer is a standing bid on a specific token (whether or not it is listed).
// The offered GNOT is escrowed in the realm until the offer is accepted by the
// token owner or withdrawn by the buyer. A buyer may hold at most one offer per
// token.
type Offer struct {
	collID  string
	tokenID string
	buyer   address
	amount  int64 // escrowed ugnot
	madeAt  int64 // block height
}

var offers avl.Tree // "collID/tokenID/buyer" -> *Offer

func offerKey(collID, tokenID string, buyer address) string {
	return collID + "/" + tokenID + "/" + buyer.String()
}

// MakeOffer escrows GNOT as an offer on a token. Re-offering replaces (and
// refunds) the caller's previous offer on the same token.
func MakeOffer(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	coll := mustGetCollection(collID)
	buyer := cur.Previous().Address()

	amount := receivedUgnot()
	if amount <= 0 {
		panic("an offer must include a positive ugnot amount")
	}

	// Disallow offering on a token you already own.
	if owner, err := coll.nft.OwnerOf(grc721.TokenID(tokenID)); err == nil && owner == buyer {
		panic("you already own this token")
	}

	key := offerKey(collID, tokenID, buyer)
	if v, exists := offers.Get(key); exists {
		payout(cur, buyer, v.(*Offer).amount) // refund the replaced offer
	}
	offers.Set(key, &Offer{collID: collID, tokenID: tokenID, buyer: buyer, amount: amount, madeAt: now()})

	chain.Emit("OfferMade", "collection", collID, "tokenId", tokenID,
		"buyer", buyer.String(), "amount", strconv.FormatInt(amount, 10))
}

// CancelOffer withdraws the caller's offer and refunds the escrowed amount.
func CancelOffer(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	buyer := cur.Previous().Address()
	key := offerKey(collID, tokenID, buyer)

	v, ok := offers.Get(key)
	if !ok {
		panic("you have no offer on this token")
	}
	o := v.(*Offer)
	offers.Remove(key)
	payout(cur, buyer, o.amount)

	chain.Emit("OfferCancelled", "collection", collID, "tokenId", tokenID, "buyer", buyer.String())
}

// AcceptOffer lets the current owner of a token accept a specific buyer's
// offer: the NFT goes to the buyer and the escrowed amount is split
// seller / royalty / fee. The token must be held by the caller (not escrowed in
// a listing or auction).
func AcceptOffer(cur realm, collID, tokenID string, buyer address) {
	assertUserCall(cur)
	coll := mustGetCollection(collID)
	owner := cur.Previous().Address()
	tid := grc721.TokenID(tokenID)

	curOwner, err := coll.nft.OwnerOf(tid)
	if err != nil {
		panic(err)
	}
	if curOwner != owner {
		panic("only the current token owner can accept an offer (delist/cancel any auction first)")
	}

	key := offerKey(collID, tokenID, buyer)
	v, ok := offers.Get(key)
	if !ok {
		panic("no such offer")
	}
	o := v.(*Offer)
	offers.Remove(key)

	if err := coll.nft.TransferFrom(owner, owner, buyer, tid); err != nil {
		panic(err)
	}
	royalty := o.amount * coll.royaltyBps / bpsDenominator
	fee := o.amount * feeBps / bpsDenominator
	sellerAmt := o.amount - royalty - fee

	feePot += fee
	payout(cur, coll.creator, royalty)
	payout(cur, owner, sellerAmt)
	recordSale(collID, tokenID, owner, buyer, o.amount, "offer")

	chain.Emit("OfferAccepted", "collection", collID, "tokenId", tokenID,
		"buyer", buyer.String(), "seller", owner.String(),
		"amount", strconv.FormatInt(o.amount, 10))
}

// GetOffer returns a buyer's offer amount on a token (read-only).
func GetOffer(collID, tokenID string, buyer address) (amount int64, exists bool) {
	v, ok := offers.Get(offerKey(collID, tokenID, buyer))
	if !ok {
		return 0, false
	}
	return v.(*Offer).amount, true
}
