// Package gnogle_market is the upgradeable marketplace layer of GNOGLE. It holds
// listings/auctions/offers/sales/fees but NEVER holds NFTs — tokens stay in
// their owners' wallets in the gnogle_nft realm. The market settles trades by
// calling gnogle_nft.TransferFrom as an approved operator. Because no NFT lives
// here, this realm can be redeployed/upgraded freely without affecting any NFT.
package gnogle_market

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	nft "gno.land/r/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/gnogle_nft"
)

const (
	ugnot          = "ugnot"
	bpsDenominator = 10000
	maxFeeBps      = 1000
)

var zeroAddr address

// Listing is a fixed-price sale. The NFT is NOT escrowed; it stays with the
// seller, who has approved this market as operator.
type Listing struct {
	collID    string
	tokenID   string
	seller    address
	price     int64
	createdAt int64
}

var (
	listings avl.Tree // "collID/tokenID" -> *Listing
	admin    address
	feeBps   int64 = 250 // 2.5%
	feePot   int64
)

// List puts a token the caller owns up for sale. The caller must first approve
// this market on gnogle_nft (SetApprovalForAll); the NFT stays in their wallet.
func List(cur realm, collID, tokenID string, price int64) {
	assertUserCall(cur)
	if price <= 0 {
		panic("price must be positive")
	}
	seller := cur.Previous().Address()
	requireOwnerAndApproval(cur, collID, tokenID, seller)
	if _, ok := getListing(collID, tokenID); ok {
		panic("token is already listed")
	}
	if _, ok := getAuction(collID, tokenID); ok {
		panic("token is in an auction")
	}
	listings.Set(key(collID, tokenID), &Listing{collID, tokenID, seller, price, runtime.ChainHeight()})
	chain.Emit("List", "collection", collID, "tokenId", tokenID, "seller", seller.String(), "price", strconv.FormatInt(price, 10))
}

// Buy purchases a listed token. The caller attaches exactly the price in ugnot.
func Buy(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	buyer := cur.Previous().Address()
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
	if nft.OwnerOf(collID, tokenID) != l.seller {
		listings.Remove(key(collID, tokenID))
		panic("listing is stale: the seller no longer owns this token")
	}
	nft.TransferFrom(cross(cur), collID, l.seller, buyer, tokenID)
	listings.Remove(key(collID, tokenID))
	settle(cur, collID, tokenID, l.seller, buyer, l.price, "buy")
	chain.Emit("Buy", "collection", collID, "tokenId", tokenID, "buyer", buyer.String(), "seller", l.seller.String(), "price", strconv.FormatInt(l.price, 10))
}

// CancelListing delists a token (no NFT moves — it never left the seller).
func CancelListing(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	caller := cur.Previous().Address()
	l, ok := getListing(collID, tokenID)
	if !ok {
		panic("token is not listed")
	}
	if caller != l.seller {
		panic("only the seller can cancel the listing")
	}
	listings.Remove(key(collID, tokenID))
	chain.Emit("Cancel", "collection", collID, "tokenId", tokenID)
}

// UpdatePrice changes a listing's price. Seller only.
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
	chain.Emit("UpdatePrice", "collection", collID, "tokenId", tokenID, "price", strconv.FormatInt(newPrice, 10))
}

// --- shared helpers ---------------------------------------------------------

// settle splits price into royalty (creator) + fee (platform) + seller, pays
// them out, and records the sale.
func settle(cur realm, collID, tokenID string, seller, buyer address, price int64, kind string) {
	creator, royaltyBps := nft.CollectionRoyalty(collID)
	royalty := price * royaltyBps / bpsDenominator
	fee := price * feeBps / bpsDenominator
	sellerAmt := price - royalty - fee
	feePot += fee
	payout(cur, creator, royalty)
	payout(cur, seller, sellerAmt)
	recordSale(collID, tokenID, seller, buyer, price, kind)
}

// requireOwnerAndApproval verifies the caller owns the token AND has approved
// this market as operator on gnogle_nft.
func requireOwnerAndApproval(cur realm, collID, tokenID string, owner address) {
	if nft.OwnerOf(collID, tokenID) != owner {
		panic("you are not the current owner of this token")
	}
	if !nft.IsApprovedForAll(owner, cur.Address()) {
		panic("approve the marketplace first: call gnogle_nft.SetApprovalForAll(<market>, true)")
	}
}

func assertUserCall(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("only direct user calls are accepted")
	}
}

func receivedUgnot() int64 {
	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != ugnot {
			panic("only ugnot is accepted")
		}
	}
	return sent.AmountOf(ugnot)
}

func payout(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin(ugnot, amount)})
}

func key(collID, tokenID string) string { return collID + "/" + tokenID }

func getListing(collID, tokenID string) (*Listing, bool) {
	v, ok := listings.Get(key(collID, tokenID))
	if !ok {
		return nil, false
	}
	return v.(*Listing), true
}
