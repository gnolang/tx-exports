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
	StatusEnded
	StatusSettled
)

func (s AuctionStatus) String() string {
	switch s {
	case StatusActive:
		return "active"
	case StatusEnded:
		return "ended"
	case StatusSettled:
		return "settled"
	default:
		return "unknown"
	}
}

type Auction struct {
	ID           int64
	Seller       address
	ItemDesc     string
	MinBid       int64
	HighBid      int64
	HighBidder   address
	EndsAt       int64
	Status       AuctionStatus
	Refunds      *avl.Tree // addr -> int64 (outstanding refundable bids)
}

const auctionDurationBlocks int64 = 200

var (
	auctions *avl.Tree // id (string) -> *Auction
	nextID   int64
)

func init() {
	auctions = avl.NewTree()
	nextID = 1
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("auctionhouse: must be a direct user call")
	}
	return cur.Previous().Address()
}

func idKey(id int64) string {
	return ufmt.Sprintf("%020d", id)
}

func getAuction(id int64) *Auction {
	key := idKey(id)
	if !auctions.Has(key) {
		panic("auctionhouse: auction not found")
	}
	raw := auctions.Get(key)
	return raw.(*Auction)
}

// CreateAuction lists a new item for auction.
func CreateAuction(cur realm, itemDesc string, minBid int64) int64 {
	caller := assertUserCall(cur)
	if minBid <= 0 {
		panic("auctionhouse: minBid must be positive")
	}
	if itemDesc == "" {
		panic("auctionhouse: item description required")
	}

	id := nextID
	nextID++

	auctions.Set(idKey(id), &Auction{
		ID:       id,
		Seller:   caller,
		ItemDesc: itemDesc,
		MinBid:   minBid,
		EndsAt:   runtime.ChainHeight() + auctionDurationBlocks,
		Status:   StatusActive,
		Refunds:  avl.NewTree(),
	})
	return id
}

// Bid places a bid on an active auction. Outbid amounts become withdrawable refunds.
func Bid(cur realm, id int64) {
	caller := assertUserCall(cur)
	a := getAuction(id)
	if a.Status != StatusActive {
		panic("auctionhouse: auction is not active")
	}
	if runtime.ChainHeight() > a.EndsAt {
		panic("auctionhouse: auction time has expired, call EndAuction")
	}

	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")

	minRequired := a.MinBid
	if a.HighBid > 0 {
		minRequired = a.HighBid + 1
	}
	if amount < minRequired {
		panic("auctionhouse: bid too low")
	}

	// Move previous high bid into refundable balance for previous bidder.
	if a.HighBid > 0 {
		prevKey := string(a.HighBidder)
		existing := int64(0)
		if a.Refunds.Has(prevKey) {
			existing = a.Refunds.Get(prevKey).(int64)
		}
		a.Refunds.Set(prevKey, existing+a.HighBid)
	}

	a.HighBid = amount
	a.HighBidder = caller
}

// WithdrawRefund lets an outbid bidder reclaim their funds.
func WithdrawRefund(cur realm, id int64) {
	caller := assertUserCall(cur)
	a := getAuction(id)

	key := string(caller)
	if !a.Refunds.Has(key) {
		panic("auctionhouse: no refund available")
	}
	amount := a.Refunds.Get(key).(int64)
	if amount <= 0 {
		panic("auctionhouse: no refund available")
	}
	a.Refunds.Set(key, int64(0))

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(realmAddr, caller, chain.Coins{chain.NewCoin("ugnot", amount)})
}

// EndAuction marks an expired auction as ended, ready for settlement.
func EndAuction(cur realm, id int64) {
	assertUserCall(cur)
	a := getAuction(id)
	if a.Status != StatusActive {
		panic("auctionhouse: auction is not active")
	}
	if runtime.ChainHeight() <= a.EndsAt {
		panic("auctionhouse: auction has not ended yet")
	}
	a.Status = StatusEnded
}

// Settle pays out the high bid to the seller.
func Settle(cur realm, id int64) {
	assertUserCall(cur)
	a := getAuction(id)
	if a.Status != StatusEnded {
		panic("auctionhouse: auction is not ended")
	}
	if a.HighBid <= 0 {
		a.Status = StatusSettled
		return
	}

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	have := bk.GetCoins(realmAddr).AmountOf("ugnot")
	amount := a.HighBid
	if amount > have {
		amount = have
	}
	bk.SendCoins(realmAddr, a.Seller, chain.Coins{chain.NewCoin("ugnot", amount)})

	a.Status = StatusSettled
}

func Render(path string) string {
	out := "# Auction House\n\n"
	out += ufmt.Sprintf("Total auctions: %d\n\n", auctions.Size())
	auctions.Iterate("", "", func(key string, value interface{}) bool {
		a := value.(*Auction)
		out += ufmt.Sprintf("## #%d: %s\n", a.ID, a.ItemDesc)
		out += ufmt.Sprintf("Status: %s | High bid: %d ugnot | Seller: %s\n\n",
			a.Status.String(), a.HighBid, a.Seller)
		return false
	})
	return out
}
