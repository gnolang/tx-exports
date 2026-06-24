package gnogle_market

import (
	"chain"
	"chain/runtime"
	"strconv"

	"gno.land/p/nt/avl/v0"
	nft "gno.land/r/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/gnogle_nft"
)

// Offer is a standing bid on a token (listed or not). The offered GNOT is
// escrowed in the market until accepted or withdrawn.
type Offer struct {
	collID  string
	tokenID string
	buyer   address
	amount  int64
	madeAt  int64
}

var offers avl.Tree // "collID/tokenID/buyer" -> *Offer

func offerKey(collID, tokenID string, buyer address) string {
	return collID + "/" + tokenID + "/" + buyer.String()
}

// MakeOffer escrows GNOT as an offer on a token. Re-offering replaces (refunds)
// the caller's previous offer.
func MakeOffer(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	buyer := cur.Previous().Address()
	amount := receivedUgnot()
	if amount <= 0 {
		panic("an offer must include a positive ugnot amount")
	}
	if nft.OwnerOf(collID, tokenID) == buyer {
		panic("you already own this token")
	}
	k := offerKey(collID, tokenID, buyer)
	if v, ok := offers.Get(k); ok {
		payout(cur, buyer, v.(*Offer).amount)
	}
	offers.Set(k, &Offer{collID, tokenID, buyer, amount, runtime.ChainHeight()})
	chain.Emit("OfferMade", "collection", collID, "tokenId", tokenID, "buyer", buyer.String(), "amount", strconv.FormatInt(amount, 10))
}

// CancelOffer withdraws the caller's offer and refunds the escrow.
func CancelOffer(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	buyer := cur.Previous().Address()
	k := offerKey(collID, tokenID, buyer)
	v, ok := offers.Get(k)
	if !ok {
		panic("you have no offer on this token")
	}
	o := v.(*Offer)
	offers.Remove(k)
	payout(cur, buyer, o.amount)
	chain.Emit("OfferCancelled", "collection", collID, "tokenId", tokenID, "buyer", buyer.String())
}

// AcceptOffer lets the current owner accept a buyer's offer. The owner must hold
// the token and have approved this market.
func AcceptOffer(cur realm, collID, tokenID string, buyer address) {
	assertUserCall(cur)
	owner := cur.Previous().Address()
	requireOwnerAndApproval(cur, collID, tokenID, owner)
	k := offerKey(collID, tokenID, buyer)
	v, ok := offers.Get(k)
	if !ok {
		panic("no such offer")
	}
	o := v.(*Offer)
	offers.Remove(k)
	nft.TransferFrom(cross(cur), collID, owner, buyer, tokenID)
	settle(cur, collID, tokenID, owner, buyer, o.amount, "offer")
	chain.Emit("OfferAccepted", "collection", collID, "tokenId", tokenID, "buyer", buyer.String(), "seller", owner.String(), "amount", strconv.FormatInt(o.amount, 10))
}
