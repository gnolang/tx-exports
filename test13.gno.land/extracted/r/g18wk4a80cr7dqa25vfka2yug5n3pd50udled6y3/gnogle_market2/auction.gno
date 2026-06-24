package gnogle_market2

import (
	"chain"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	nft "gno.land/r/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/gnogle_nft2"
)

// Auction is a timed English auction. The NFT is NOT escrowed (it stays with the
// seller); only the highest bid funds are held by the market.
type Auction struct {
	collID        string
	tokenID       string
	seller        address
	minBid        int64
	highestBid    int64
	highestBidder address
	endTime       time.Time
	settled       bool
}

var auctions avl.Tree // "collID/tokenID" -> *Auction

func getAuction(collID, tokenID string) (*Auction, bool) {
	v, ok := auctions.Get(key(collID, tokenID))
	if !ok {
		return nil, false
	}
	return v.(*Auction), true
}

func mustGetAuction(collID, tokenID string) *Auction {
	a, ok := getAuction(collID, tokenID)
	if !ok {
		panic("no active auction for this token")
	}
	return a
}

// CreateAuction opens an auction for a token the caller owns (and has approved
// this market for).
func CreateAuction(cur realm, collID, tokenID string, minBid, durationSecs int64) {
	assertUserCall(cur)
	if minBid < 0 {
		panic("minBid cannot be negative")
	}
	if durationSecs <= 0 {
		panic("duration must be positive")
	}
	seller := cur.Previous().Address()
	requireOwnerAndApproval(cur, collID, tokenID, seller)
	if _, ok := getAuction(collID, tokenID); ok {
		panic("token is already in an auction")
	}
	if _, ok := getListing(collID, tokenID); ok {
		panic("token is listed for sale; cancel that listing first")
	}
	auctions.Set(key(collID, tokenID), &Auction{
		collID: collID, tokenID: tokenID, seller: seller, minBid: minBid,
		endTime: time.Now().Add(time.Duration(durationSecs) * time.Second),
	})
	chain.Emit("AuctionCreated", "collection", collID, "tokenId", tokenID, "seller", seller.String(), "minBid", strconv.FormatInt(minBid, 10))
}

// Bid places a bid; attach GNOT greater than the current highest. The previous
// highest bidder is refunded.
func Bid(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	a := mustGetAuction(collID, tokenID)
	bidder := cur.Previous().Address()
	if a.settled {
		panic("auction already settled")
	}
	if !time.Now().Before(a.endTime) {
		panic("auction has ended")
	}
	if bidder == a.seller {
		panic("seller cannot bid on their own auction")
	}
	amount := receivedUgnot()
	if amount < a.minBid {
		panic(ufmt.Sprintf("bid must be at least %d ugnot", a.minBid))
	}
	if amount <= a.highestBid {
		panic(ufmt.Sprintf("bid must exceed the current highest bid of %d ugnot", a.highestBid))
	}
	if a.highestBid > 0 && a.highestBidder != zeroAddr {
		payout(cur, a.highestBidder, a.highestBid)
	}
	a.highestBid = amount
	a.highestBidder = bidder
	chain.Emit("Bid", "collection", collID, "tokenId", tokenID, "bidder", bidder.String(), "amount", strconv.FormatInt(amount, 10))
}

// EndAuction settles an auction after its end time. With a winning bid the NFT
// goes to the winner (if the seller still owns it and the market is still
// approved); otherwise the winner is refunded.
func EndAuction(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	a := mustGetAuction(collID, tokenID)
	if a.settled {
		panic("auction already settled")
	}
	if time.Now().Before(a.endTime) {
		panic("auction has not ended yet")
	}
	a.settled = true
	auctions.Remove(key(collID, tokenID))

	if a.highestBid == 0 {
		chain.Emit("AuctionEnded", "collection", collID, "tokenId", tokenID, "winner", "", "amount", "0")
		return
	}
	// Seller must still own the token and keep the market approved; else refund.
	if nft.OwnerOf(collID, tokenID) != a.seller || !marketApproved(cur, collID, tokenID, a.seller) {
		payout(cur, a.highestBidder, a.highestBid)
		chain.Emit("AuctionVoided", "collection", collID, "tokenId", tokenID, "refunded", a.highestBidder.String())
		return
	}
	nft.TransferFrom(cross(cur), collID, a.seller, a.highestBidder, tokenID)
	settle(cur, collID, tokenID, a.seller, a.highestBidder, a.highestBid, "auction")
	chain.Emit("AuctionEnded", "collection", collID, "tokenId", tokenID, "winner", a.highestBidder.String(), "amount", strconv.FormatInt(a.highestBid, 10))
}
