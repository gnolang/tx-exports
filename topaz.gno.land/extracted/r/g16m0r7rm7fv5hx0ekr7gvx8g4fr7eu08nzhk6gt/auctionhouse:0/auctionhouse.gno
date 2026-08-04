package auctionhouse

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type AuctionStatus int

const (
	StatusActive AuctionStatus = iota
	StatusSettledSold
	StatusSettledUnsold
)

func (s AuctionStatus) String() string {
	switch s {
	case StatusActive:
		return "Active"
	case StatusSettledSold:
		return "SettledSold"
	case StatusSettledUnsold:
		return "SettledUnsold"
	default:
		return "Unknown"
	}
}

const antiSnipeWindow = 10

type Auction struct {
	ID              int64
	Seller          address
	ItemDescription string
	ReservePrice    int64
	EndHeight       int64
	HighestBidder   address
	HighestBid      int64
	Status          AuctionStatus
}

var (
	auctions      = avl.NewTree()
	nextAuctionID int64
)

func CreateAuction(cur realm, itemDescription string, reservePrice int64, durationBlocks int64) int64 {
	if !cur.Previous().IsUserCall() {
		panic("auctionhouse: only direct user calls can create auctions")
	}
	if itemDescription == "" {
		panic("auctionhouse: item description cannot be empty")
	}
	if reservePrice <= 0 {
		panic("auctionhouse: reserve price must be positive")
	}
	if durationBlocks <= 0 {
		panic("auctionhouse: durationBlocks must be positive")
	}

	seller := cur.Previous().Address()
	nowHeight := runtime.ChainHeight()

	nextAuctionID++
	id := nextAuctionID

	a := &Auction{
		ID:              id,
		Seller:          seller,
		ItemDescription: itemDescription,
		ReservePrice:    reservePrice,
		EndHeight:       nowHeight + durationBlocks,
		Status:          StatusActive,
	}

	auctions.Set(itoa(id), a)
	return id
}

func Bid(cur realm, auctionID int64) {
	if !cur.Previous().IsUserCall() {
		panic("auctionhouse: only direct user calls can bid")
	}

	a := mustGetAuction(auctionID)
	bidder := cur.Previous().Address()

	if a.Status != StatusActive {
		panic("auctionhouse: auction is not active (status=" + a.Status.String() + ")")
	}

	nowHeight := runtime.ChainHeight()
	if nowHeight >= a.EndHeight {
		panic("auctionhouse: auction has already ended")
	}
	if bidder == a.Seller {
		panic("auctionhouse: seller cannot bid on their own auction")
	}

	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("auctionhouse: bid must include a positive ugnot amount")
	}

	if a.HighestBidder == "" {
		if amount < a.ReservePrice {
			panic("auctionhouse: first bid must meet the reserve price")
		}
	} else {
		if amount <= a.HighestBid {
			panic("auctionhouse: bid must exceed the current highest bid")
		}
	}

	previousBidder := a.HighestBidder
	previousAmount := a.HighestBid

	a.HighestBidder = bidder
	a.HighestBid = amount
	if a.EndHeight-nowHeight <= antiSnipeWindow {
		a.EndHeight = nowHeight + antiSnipeWindow
	}

	if previousBidder != "" {
		payout(cur, previousBidder, previousAmount)
	}
}

func Finalize(cur realm, auctionID int64) {
	a := mustGetAuction(auctionID)

	if a.Status != StatusActive {
		panic("auctionhouse: auction is not active (status=" + a.Status.String() + ")")
	}
	if runtime.ChainHeight() < a.EndHeight {
		panic("auctionhouse: auction has not ended yet")
	}

	if a.HighestBidder == "" {
		a.Status = StatusSettledUnsold
		return
	}

	winningBid := a.HighestBid
	seller := a.Seller

	a.Status = StatusSettledSold

	payout(cur, seller, winningBid)
}

func mustGetAuction(auctionID int64) *Auction {
	raw := auctions.Get(itoa(auctionID))
	if raw == nil {
		panic("auctionhouse: auction not found")
	}
	a, ok := raw.(*Auction)
	if !ok {
		panic("auctionhouse: internal error, corrupted auction entry")
	}
	return a
}

func payout(cur realm, to address, amount int64) {
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	have := b.GetCoins(realmAddr).AmountOf("ugnot")
	if have < amount {
		panic("auctionhouse: internal invariant violation, insufficient realm balance for payout")
	}

	b.SendCoins(realmAddr, to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

func itoa(i int64) string {
	return ufmt.Sprintf("%d", i)
}

func GetAuctionStatus(auctionID int64) string {
	return mustGetAuction(auctionID).Status.String()
}

func GetAuctionSeller(auctionID int64) address {
	return mustGetAuction(auctionID).Seller
}

func GetAuctionReservePrice(auctionID int64) int64 {
	return mustGetAuction(auctionID).ReservePrice
}

func GetAuctionEndHeight(auctionID int64) int64 {
	return mustGetAuction(auctionID).EndHeight
}

func GetAuctionHighestBidder(auctionID int64) address {
	return mustGetAuction(auctionID).HighestBidder
}

func GetAuctionHighestBid(auctionID int64) int64 {
	return mustGetAuction(auctionID).HighestBid
}
