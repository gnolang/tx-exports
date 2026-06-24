package nftmarket

import (
	"chain"
	"strconv"
	"time"

	"gno.land/p/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/grc721"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Auction is a timed English auction. While it runs, the NFT is escrowed in
// the realm and the current highest bid is held by the realm (the previous
// highest bidder is refunded whenever a higher bid arrives).
type Auction struct {
	collID        string
	tokenID       string
	seller        address
	minBid        int64     // minimum first bid, in ugnot
	highestBid    int64     // 0 when there are no bids yet
	highestBidder address   // zero address when there are no bids yet
	endTime       time.Time // auction closes at this block time
	settled       bool
}

var auctions avl.Tree // "collID/tokenID" -> *Auction

// CreateAuction escrows the caller's token and opens an auction that runs for
// durationSecs seconds. minBid is the minimum acceptable first bid (ugnot).
func CreateAuction(cur realm, collID, tokenID string, minBid, durationSecs int64) {
	assertUserCall(cur)
	if minBid < 0 {
		panic("minBid cannot be negative")
	}
	if durationSecs <= 0 {
		panic("duration must be positive")
	}
	coll := mustGetCollection(collID)
	seller := cur.Previous().Address()
	tid := grc721.TokenID(tokenID)

	if _, exists := auctions.Get(listingKey(collID, tokenID)); exists {
		panic("token is already in an auction")
	}
	if _, listed := getListing(collID, tokenID); listed {
		panic("token is listed for fixed-price sale; cancel that listing first")
	}

	owner, err := coll.nft.OwnerOf(tid)
	if err != nil {
		panic(err)
	}
	if owner != seller {
		panic("only the token owner can auction it")
	}

	// escrow the NFT in the realm for the duration of the auction
	if err := coll.nft.TransferFrom(seller, seller, cur.Address(), tid); err != nil {
		panic(err)
	}

	auctions.Set(listingKey(collID, tokenID), &Auction{
		collID:        collID,
		tokenID:       tokenID,
		seller:        seller,
		minBid:        minBid,
		highestBid:    0,
		highestBidder: zeroAddr,
		endTime:       time.Now().Add(time.Duration(durationSecs) * time.Second),
		settled:       false,
	})

	chain.Emit("AuctionCreated", "collection", collID, "tokenId", tokenID,
		"seller", seller.String(), "minBid", strconv.FormatInt(minBid, 10))
}

// Bid places a bid on a running auction. Attach GNOT strictly greater than the
// current highest bid (and at least minBid). The previous highest bidder is
// refunded automatically.
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

	// refund the previous highest bidder, if any
	if a.highestBid > 0 && a.highestBidder != zeroAddr {
		payout(cur, a.highestBidder, a.highestBid)
	}
	a.highestBid = amount
	a.highestBidder = bidder

	chain.Emit("Bid", "collection", collID, "tokenId", tokenID,
		"bidder", bidder.String(), "amount", strconv.FormatInt(amount, 10))
}

// EndAuction settles an auction once its end time has passed. Anyone may call
// it. With a winning bid the NFT goes to the winner and the proceeds are split
// seller / royalty / fee; with no bids the NFT is returned to the seller.
func EndAuction(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	a := mustGetAuction(collID, tokenID)
	if a.settled {
		panic("auction already settled")
	}
	if time.Now().Before(a.endTime) {
		panic("auction has not ended yet")
	}

	coll := mustGetCollection(collID)
	tid := grc721.TokenID(tokenID)
	a.settled = true
	auctions.Remove(listingKey(collID, tokenID))

	// no bids: return the NFT to the seller
	if a.highestBid == 0 {
		if err := coll.nft.TransferFrom(cur.Address(), cur.Address(), a.seller, tid); err != nil {
			panic(err)
		}
		chain.Emit("AuctionEnded", "collection", collID, "tokenId", tokenID, "winner", "", "amount", "0")
		return
	}

	// winning bid: NFT to winner, split the proceeds
	if err := coll.nft.TransferFrom(cur.Address(), cur.Address(), a.highestBidder, tid); err != nil {
		panic(err)
	}
	royalty := a.highestBid * coll.royaltyBps / bpsDenominator
	fee := a.highestBid * feeBps / bpsDenominator
	sellerAmt := a.highestBid - royalty - fee

	feePot += fee
	payout(cur, coll.creator, royalty)
	payout(cur, a.seller, sellerAmt)

	chain.Emit("AuctionEnded", "collection", collID, "tokenId", tokenID,
		"winner", a.highestBidder.String(), "amount", strconv.FormatInt(a.highestBid, 10))
}

func mustGetAuction(collID, tokenID string) *Auction {
	v, ok := auctions.Get(listingKey(collID, tokenID))
	if !ok {
		panic("no active auction for this token")
	}
	return v.(*Auction)
}

func getAuction(collID, tokenID string) (*Auction, bool) {
	v, ok := auctions.Get(listingKey(collID, tokenID))
	if !ok {
		return nil, false
	}
	return v.(*Auction), true
}

// GetAuction returns the current state of an auction (read-only).
func GetAuction(collID, tokenID string) (seller address, minBid, highestBid int64, highestBidder address, endUnix int64, active bool) {
	a, ok := getAuction(collID, tokenID)
	if !ok {
		return zeroAddr, 0, 0, zeroAddr, 0, false
	}
	return a.seller, a.minBid, a.highestBid, a.highestBidder, a.endTime.Unix(), true
}
