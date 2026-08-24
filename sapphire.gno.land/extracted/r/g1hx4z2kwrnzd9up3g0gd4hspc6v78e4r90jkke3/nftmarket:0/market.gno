// Package nftmarket is a non-custodial GNOT marketplace for collections
// minted through gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft.
//
// Non-custodial: listing a token never moves it into this realm. Instead
// the seller approves this realm's address as an operator on
// gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft (Approve or SetApprovalForAll), and List just
// records the intent to sell. At Buy time this realm cross-calls
// nft.TransferFrom on the seller's behalf — which only succeeds while the
// approval still stands — so a seller can invalidate every open listing
// at once just by transferring the token or revoking the approval.
package nftmarket

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft"
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
	listings = avl.NewTree() // listingID -> *Listing
	byToken  = avl.NewTree() // "collectionId:tokenId" -> listingID (only one active listing per token)
	nextID   int64
)

// List offers a token for sale at priceUgnot (denominated in ugnot, i.e.
// 1 GNOT = 1_000_000). The caller must already own the token and must have
// approved this realm's address on gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft beforehand
// (nft.Approve or nft.SetApprovalForAll), otherwise Buy will fail later.
func List(cur realm, collectionID, tokenID string, priceUgnot int64) string {
	// List/Cancel/Buy are always meant to be called directly by an EOA,
	// so caller comes from unsafe.OriginCaller() (the tx's real signer)
	// rather than cur.Previous().Address(). Only nft.TransferFrom (called
	// from Buy below) actually needs the direct-caller distinction, to
	// let this realm act as the seller's approved operator.
	caller := unsafe.OriginCaller()
	if priceUgnot <= 0 {
		panic("price must be positive")
	}

	owner, err := nft.OwnerOf(collectionID, tokenID)
	if err != nil {
		panic(err)
	}
	if owner != caller {
		panic("only the token owner can list it")
	}

	marketAddr := cur.Address()
	approved, _ := nft.GetApproved(collectionID, tokenID)
	if approved != marketAddr && !nft.IsApprovedForAll(collectionID, owner, marketAddr) {
		panic("marketplace is not approved to transfer this token yet; call nft.Approve or nft.SetApprovalForAll first")
	}

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

// Cancel withdraws an active listing. Only the original seller may cancel.
func Cancel(cur realm, listingID string) {
	caller := unsafe.OriginCaller()
	l := mustGetListing(listingID)
	if !l.active {
		panic("listing is not active")
	}
	if l.seller != caller {
		panic("only the seller can cancel this listing")
	}

	l.active = false
	byToken.Remove(l.collectionID + ":" + l.tokenID)

	chain.Emit("NFTListingCancelled", "listingId", listingID)
}

// Buy purchases an active listing. The transaction must send at least the
// listing's priceUgnot in ugnot (--send "<price>ugnot" on maketx call); any
// excess is refunded to the buyer. Royalties declared on the token (via
// its collection's royaltyPct, set automatically at Mint) are paid to the
// collection creator before the remainder goes to the seller.
func Buy(cur realm, listingID string) {
	caller := unsafe.OriginCaller()
	l := mustGetListing(listingID)
	if !l.active {
		panic("listing is not active")
	}
	if l.seller == caller {
		panic("cannot buy your own listing")
	}

	sent := unsafe.OriginSend()
	sentAmt := sent.AmountOf("ugnot")
	if sentAmt < l.priceUgnot {
		panic("insufficient payment: sent " + strconv.FormatInt(sentAmt, 10) +
			"ugnot, need " + strconv.FormatInt(l.priceUgnot, 10) + "ugnot")
	}

	marketAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	sellerAmt := l.priceUgnot
	if royaltyAddr, royaltyAmt, err := nft.RoyaltyInfo(l.collectionID, l.tokenID, l.priceUgnot); err == nil {
		if royaltyAmt > 0 && royaltyAmt < l.priceUgnot && royaltyAddr != l.seller {
			sellerAmt = l.priceUgnot - royaltyAmt
			bk.SendCoins(marketAddr, royaltyAddr, chain.NewCoins(chain.NewCoin("ugnot", royaltyAmt)))
		}
	}
	bk.SendCoins(marketAddr, l.seller, chain.NewCoins(chain.NewCoin("ugnot", sellerAmt)))

	if sentAmt > l.priceUgnot {
		bk.SendCoins(marketAddr, caller, chain.NewCoins(chain.NewCoin("ugnot", sentAmt-l.priceUgnot)))
	}

	// Cross into gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft to move ownership. This only
	// succeeds if the seller's approval (granted directly on the nft
	// realm) is still standing; a revoked/expired approval reverts this
	// entire transaction, including the coin transfers above.
	nft.TransferFrom(cross(cur), l.collectionID, l.tokenID, l.seller, caller)

	l.active = false
	byToken.Remove(l.collectionID + ":" + l.tokenID)

	chain.Emit(
		"NFTSold",
		"listingId", listingID,
		"collection", l.collectionID,
		"tokenId", l.tokenID,
		"seller", l.seller.String(),
		"buyer", caller.String(),
		"price", strconv.FormatInt(l.priceUgnot, 10),
	)
}

// Read-only views.

// GetListing returns one listing by ID.
func GetListing(listingID string) ListingInfo {
	return toInfo(mustGetListing(listingID))
}

// ListActive returns up to `limit` active listings starting at `offset`
// (offset/limit apply to the full listing set, active or not, so callers
// should over-fetch slightly if they need an exact page of active-only
// results).
func ListActive(offset, limit int64) []ListingInfo {
	out := make([]ListingInfo, 0, limit)
	listings.IterateByOffset(int(offset), int(limit), func(key string, value any) bool {
		l := value.(*Listing)
		if l.active {
			out = append(out, toInfo(l))
		}
		return false
	})
	return out
}

// ListingCount returns the total number of listings ever created
// (active + inactive).
func ListingCount() int64 {
	return nextID
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

	out := "# Hazen NFT Marketplace\n\n"
	hasActive := false
	listings.Iterate("", "", func(key string, value any) bool {
		l := value.(*Listing)
		if !l.active {
			return false
		}
		hasActive = true
		out += renderListing(l) + "\n"
		return false
	})
	if !hasActive {
		out += "No active listings.\n"
	}
	return out
}

func renderListing(l *Listing) string {
	status := "active"
	if !l.active {
		status = "sold/cancelled"
	}
	return "- #" + l.id + " " + l.collectionID + ":" + l.tokenID +
		" — " + strconv.FormatInt(l.priceUgnot, 10) + "ugnot — seller " + l.seller.String() +
		" (" + status + ")"
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
