package auction

import "strconv"

type Auction struct {
	Item    string
	Highest int64
	Winner  string
	Ended   bool
}

var auction *Auction

func init() {
	auction = &Auction{Item: "Pearl NFT #1"}
}

func Bid(bidder string, amount int64) {
	if auction.Ended {
		panic("auction ended")
	}
	if amount <= auction.Highest {
		panic("bid too low")
	}
	auction.Highest = amount
	auction.Winner = bidder
}

func End() {
	auction.Ended = true
}

func Status() (string, int64, string, bool) {
	return auction.Item, auction.Highest, auction.Winner, auction.Ended
}

func Render(_ string) string {
	out := "auction: " + auction.Item + "\n"
	out += "highest bid: " + strconv.Itoa(int(auction.Highest)) + "\n"
	if auction.Winner != "" {
		out += "winner: " + auction.Winner + "\n"
	}
	if auction.Ended {
		out += "status: ended\n"
	} else {
		out += "status: active\n"
	}
	return out
}
