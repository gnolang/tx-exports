// Package nftoffers is a non-custodial offer/bid system for tokens minted
// through gno.land/r/hazen/nft. It is a separate realm from nftmarket
// (rather than an addition to it) because gno.land packages are immutable
// once deployed — nftmarket was already live with real listings, so any
// new feature has to ship as its own realm instead of an in-place upgrade.
//
// Unlike nftmarket's List/Buy (seller sets a fixed price, first buyer
// wins), offers let any interested buyer propose a price on ANY token —
// listed on nftmarket or not — by escrowing GNOT in this realm up front.
// The token owner can then Accept the best/any offer at their discretion,
// or the buyer can Cancel to get a full refund while it's still pending.
//
// Escrow model: MakeOffer's --send amount is credited to this realm's own
// balance (that's how a `/vm.m_call` with a send value works), and stays
// there until AcceptOffer pays it out (to the seller, minus royalty) or
// CancelOffer refunds it to the original buyer. The NFT itself is never
// escrowed — same non-custodial approval pattern as nftmarket: the owner
// must Approve/SetApprovalForAll this realm's address on nft.gno before
// AcceptOffer's cross-realm TransferFrom can succeed.
package nftoffers

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft"
)

// Offer is one pending or historical bid on a token.
type Offer struct {
	id           string
	collectionID string
	tokenID      string
	buyer        address
	amountUgnot  int64
	active       bool
	createdAt    int64
}

// OfferInfo is the exported, read-only view of an Offer.
type OfferInfo struct {
	ID           string
	CollectionID string
	TokenID      string
	Buyer        address
	AmountUgnot  int64
	Active       bool
	CreatedAt    int64
}

var (
	offers = avl.NewTree() // offerID -> *Offer
	nextID int64
)

// MakeOffer escrows the transaction's --send amount (in ugnot) as an offer
// on collectionID:tokenID. Any number of offers can be pending on the same
// token at once (from the same or different buyers); the owner chooses
// which, if any, to Accept. The token does not need to be owned by anyone
// in particular other than "not the caller" — offers work whether or not
// the token is also listed on nftmarket.
func MakeOffer(cur realm, collectionID, tokenID string) string {
	caller := unsafe.OriginCaller()

	sent := unsafe.OriginSend()
	amt := sent.AmountOf("ugnot")
	if amt <= 0 {
		panic("offer must send a positive ugnot amount")
	}

	owner, err := nft.OwnerOf(collectionID, tokenID)
	if err != nil {
		panic(err)
	}
	if owner == caller {
		panic("cannot make an offer on your own token")
	}

	nextID++
	id := strconv.FormatInt(nextID, 10)
	o := &Offer{
		id:           id,
		collectionID: collectionID,
		tokenID:      tokenID,
		buyer:        caller,
		amountUgnot:  amt,
		active:       true,
		createdAt:    runtime.ChainHeight(),
	}
	offers.Set(id, o)

	chain.Emit(
		"OfferMade",
		"offerId", id,
		"collection", collectionID,
		"tokenId", tokenID,
		"buyer", caller.String(),
		"amount", strconv.FormatInt(amt, 10),
	)

	return id
}

// CancelOffer withdraws a pending offer and refunds the escrowed amount to
// the buyer. Only the buyer who made the offer may cancel it.
func CancelOffer(cur realm, offerID string) {
	caller := unsafe.OriginCaller()
	o := mustGetOffer(offerID)
	if !o.active {
		panic("offer is not active")
	}
	if o.buyer != caller {
		panic("only the offer's buyer can cancel it")
	}

	o.active = false

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), o.buyer, chain.NewCoins(chain.NewCoin("ugnot", o.amountUgnot)))

	chain.Emit("OfferCancelled", "offerId", offerID)
}

// AcceptOffer sells the token to the offer's buyer at the offer's escrowed
// price. Only the token's current owner may accept, and the owner must
// have already approved this realm's address on nft.gno (Approve or
// SetApprovalForAll), the same non-custodial pattern nftmarket uses.
// Royalties are paid out automatically, same as nftmarket.Buy.
func AcceptOffer(cur realm, offerID string) {
	caller := unsafe.OriginCaller()
	o := mustGetOffer(offerID)
	if !o.active {
		panic("offer is not active")
	}

	owner, err := nft.OwnerOf(o.collectionID, o.tokenID)
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
	approved, _ := nft.GetApproved(o.collectionID, o.tokenID)
	if approved != realmAddr && !nft.IsApprovedForAll(o.collectionID, owner, realmAddr) {
		panic("nftoffers is not approved to transfer this token yet; call nft.Approve or nft.SetApprovalForAll first")
	}

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	sellerAmt := o.amountUgnot
	if royaltyAddr, royaltyAmt, err := nft.RoyaltyInfo(o.collectionID, o.tokenID, o.amountUgnot); err == nil {
		if royaltyAmt > 0 && royaltyAmt < o.amountUgnot && royaltyAddr != owner {
			sellerAmt = o.amountUgnot - royaltyAmt
			bk.SendCoins(realmAddr, royaltyAddr, chain.NewCoins(chain.NewCoin("ugnot", royaltyAmt)))
		}
	}
	bk.SendCoins(realmAddr, owner, chain.NewCoins(chain.NewCoin("ugnot", sellerAmt)))

	// Cross into nft.gno to move ownership, same approval-dependent
	// pattern as nftmarket.Buy: this reverts the whole tx (including the
	// coin transfers above) if the owner's approval no longer stands.
	nft.TransferFrom(cross(cur), o.collectionID, o.tokenID, owner, o.buyer)

	o.active = false

	chain.Emit(
		"OfferAccepted",
		"offerId", offerID,
		"collection", o.collectionID,
		"tokenId", o.tokenID,
		"seller", owner.String(),
		"buyer", o.buyer.String(),
		"amount", strconv.FormatInt(o.amountUgnot, 10),
	)
}

// Read-only views.

// GetOffer returns one offer by ID.
func GetOffer(offerID string) OfferInfo {
	return toInfo(mustGetOffer(offerID))
}

// OffersForToken returns every active offer on one token, most recent
// first. Fine to iterate the full offer set at this project's scale;
// revisit with a secondary "collectionId:tokenId -> []offerId" index if
// the offer volume ever makes this too slow.
func OffersForToken(collectionID, tokenID string) []OfferInfo {
	var out []OfferInfo
	offers.Iterate("", "", func(key string, value any) bool {
		o := value.(*Offer)
		if o.active && o.collectionID == collectionID && o.tokenID == tokenID {
			out = append(out, toInfo(o))
		}
		return false
	})
	return out
}

// OffersByBuyer returns every active offer the given address has made,
// so a buyer can see/cancel their own pending offers (the "My Offers"
// counterpart to nftmarket's "My Listings").
func OffersByBuyer(buyer address) []OfferInfo {
	var out []OfferInfo
	offers.Iterate("", "", func(key string, value any) bool {
		o := value.(*Offer)
		if o.active && o.buyer == buyer {
			out = append(out, toInfo(o))
		}
		return false
	})
	return out
}

// OfferCount returns the total number of offers ever created (active +
// inactive).
func OfferCount() int64 {
	return nextID
}

// Render implements the gno.land realm home-page convention.
func Render(path string) string {
	if path != "" {
		o, ok := offers.Get(path).(*Offer)
		if !ok {
			return "# 404\n\noffer not found: " + path
		}
		return renderOffer(o)
	}

	out := "# Hazen NFT Offers\n\n"
	hasActive := false
	offers.Iterate("", "", func(key string, value any) bool {
		o := value.(*Offer)
		if !o.active {
			return false
		}
		hasActive = true
		out += renderOffer(o) + "\n"
		return false
	})
	if !hasActive {
		out += "No active offers.\n"
	}
	return out
}

func renderOffer(o *Offer) string {
	status := "active"
	if !o.active {
		status = "resolved"
	}
	return "- #" + o.id + " " + o.collectionID + ":" + o.tokenID +
		" — " + strconv.FormatInt(o.amountUgnot, 10) + "ugnot — buyer " + o.buyer.String() +
		" (" + status + ")"
}

func toInfo(o *Offer) OfferInfo {
	return OfferInfo{
		ID:           o.id,
		CollectionID: o.collectionID,
		TokenID:      o.tokenID,
		Buyer:        o.buyer,
		AmountUgnot:  o.amountUgnot,
		Active:       o.active,
		CreatedAt:    o.createdAt,
	}
}

func mustGetOffer(id string) *Offer {
	v := offers.Get(id)
	if v == nil {
		panic("offer not found: " + id)
	}
	return v.(*Offer)
}
