package nftmarket

import (
	"chain"
	"strconv"

	"gno.land/p/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/grc721"
	"gno.land/p/nt/ufmt/v0"
)

// List puts a token the caller owns up for sale at a fixed price (in ugnot).
// The NFT is escrowed in the realm until the listing is bought or cancelled.
func List(cur realm, collID, tokenID string, price int64) {
	assertUserCall(cur)
	if price <= 0 {
		panic("price must be positive")
	}
	coll := mustGetCollection(collID)
	seller := cur.Previous().Address()
	tid := grc721.TokenID(tokenID)

	owner, err := coll.nft.OwnerOf(tid)
	if err != nil {
		panic(err)
	}
	if owner != seller {
		panic("only the token owner can list it")
	}
	if _, exists := getListing(collID, tokenID); exists {
		panic("token is already listed")
	}

	// Escrow: move the NFT into the realm's custody.
	if err := coll.nft.TransferFrom(seller, seller, cur.Address(), tid); err != nil {
		panic(err)
	}

	listings.Set(listingKey(collID, tokenID), &Listing{
		collID:    collID,
		tokenID:   tokenID,
		seller:    seller,
		price:     price,
		createdAt: now(),
	})

	chain.Emit("List", "collection", collID, "tokenId", tokenID,
		"seller", seller.String(), "price", strconv.FormatInt(price, 10))
}

// Buy purchases a listed token. The caller must attach exactly the listing
// price in ugnot. The price is split: royalty -> collection creator,
// fee -> platform, remainder -> seller. The NFT is transferred to the buyer.
func Buy(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	coll := mustGetCollection(collID)
	buyer := cur.Previous().Address()
	tid := grc721.TokenID(tokenID)

	l, ok := getListing(collID, tokenID)
	if !ok {
		panic("token is not listed for sale")
	}
	if buyer == l.seller {
		panic("cannot buy your own listing")
	}

	paid := receivedUgnot()
	if paid != l.price {
		panic(ufmt.Sprintf("must send exactly %d ugnot to buy (sent %d)", l.price, paid))
	}

	// Split the proceeds. royaltyBps (<=5000) + feeBps (<=1000) < 10000, so the
	// seller always nets a positive amount.
	royalty := l.price * coll.royaltyBps / bpsDenominator
	fee := l.price * feeBps / bpsDenominator
	sellerAmt := l.price - royalty - fee

	// Hand the NFT to the buyer and drop the listing before paying out.
	if err := coll.nft.TransferFrom(cur.Address(), cur.Address(), buyer, tid); err != nil {
		panic(err)
	}
	listings.Remove(listingKey(collID, tokenID))

	feePot += fee
	payout(cur, coll.creator, royalty)
	payout(cur, l.seller, sellerAmt)

	chain.Emit("Buy", "collection", collID, "tokenId", tokenID,
		"buyer", buyer.String(), "seller", l.seller.String(),
		"price", strconv.FormatInt(l.price, 10))
}

// CancelListing delists a token and returns it from escrow to the seller.
func CancelListing(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	coll := mustGetCollection(collID)
	caller := cur.Previous().Address()

	l, ok := getListing(collID, tokenID)
	if !ok {
		panic("token is not listed")
	}
	if caller != l.seller {
		panic("only the seller can cancel the listing")
	}

	if err := coll.nft.TransferFrom(cur.Address(), cur.Address(), l.seller, grc721.TokenID(tokenID)); err != nil {
		panic(err)
	}
	listings.Remove(listingKey(collID, tokenID))

	chain.Emit("Cancel", "collection", collID, "tokenId", tokenID, "seller", l.seller.String())
}

// UpdatePrice changes the asking price of an active listing. Seller only.
func UpdatePrice(cur realm, collID, tokenID string, newPrice int64) {
	assertUserCall(cur)
	if newPrice <= 0 {
		panic("price must be positive")
	}
	caller := cur.Previous().Address()

	l, ok := getListing(collID, tokenID)
	if !ok {
		panic("token is not listed")
	}
	if caller != l.seller {
		panic("only the seller can update the price")
	}
	l.price = newPrice

	chain.Emit("UpdatePrice", "collection", collID, "tokenId", tokenID,
		"price", strconv.FormatInt(newPrice, 10))
}

// --- read-only views (callable via vm/qeval) --------------------------------

// OwnerOf returns the on-chain owner of a token, or the zero address if the
// token does not exist. A listed token is owned by the realm (escrow).
func OwnerOf(collID, tokenID string) address {
	coll, ok := collections.Get(collID)
	if !ok {
		return zeroAddr
	}
	owner, err := coll.(*Collection).nft.OwnerOf(grc721.TokenID(tokenID))
	if err != nil {
		return zeroAddr
	}
	return owner
}

// GetListing returns the seller, price and whether the token is currently listed.
func GetListing(collID, tokenID string) (seller address, price int64, listed bool) {
	l, ok := getListing(collID, tokenID)
	if !ok {
		return zeroAddr, 0, false
	}
	return l.seller, l.price, true
}

// TokenURI returns the metadata URI for a token (baseURI + tokenID).
func TokenURI(collID, tokenID string) string {
	coll, ok := collections.Get(collID)
	if !ok {
		return ""
	}
	return coll.(*Collection).baseURI + tokenID
}

// CollectionInfo returns the public configuration of a collection.
func CollectionInfo(id string) (name, symbol string, creator address, mintPrice, maxSupply, minted, royaltyBps int64) {
	coll := mustGetCollection(id)
	return coll.name, coll.symbol, coll.creator, coll.mintPrice, coll.maxSupply, coll.minted, coll.royaltyBps
}
