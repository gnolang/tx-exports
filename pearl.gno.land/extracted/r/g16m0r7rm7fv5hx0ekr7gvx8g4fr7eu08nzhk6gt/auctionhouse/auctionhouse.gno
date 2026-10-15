package auctionhouse

type Status int

const (
	StatusActive Status = iota
	StatusEnded
	StatusFinalized
	StatusCancelled
)

type Auction struct {
	ID            string
	Seller        string
	Item          string
	MinBid        int64
	HighestBid    int64
	HighestBidder string
	EndHeight     int64
	Status        Status
	BidCount      int
}

type House struct {
	auctions      map[string]*Auction
	refunds       map[string]int64 // address -> amount owed
	currentHeight int64
	nextSeq       int64
	admin         string
}

func NewHouse(admin string) *House {
	return &House{
		auctions: make(map[string]*Auction),
		refunds:  make(map[string]int64),
		admin:    admin,
	}
}

// Tick advances the house's notion of the current block height.
// Called externally since std.GetHeight is not usable on this chain yet.
func (h *House) Tick(height int64) {
	if height > h.currentHeight {
		h.currentHeight = height
	}
}

func (h *House) CreateAuction(seller, item string, minBid, durationBlocks int64) (string, bool) {
	if minBid <= 0 || durationBlocks <= 0 || seller == "" || item == "" {
		return "", false
	}
	h.nextSeq++
	id := itoa(h.nextSeq)
	h.auctions[id] = &Auction{
		ID:        id,
		Seller:    seller,
		Item:      item,
		MinBid:    minBid,
		EndHeight: h.currentHeight + durationBlocks,
		Status:    StatusActive,
	}
	return id, true
}

func (h *House) Bid(auctionID, bidder string, amount int64) bool {
	a, ok := h.auctions[auctionID]
	if !ok || a.Status != StatusActive {
		return false
	}
	if h.currentHeight >= a.EndHeight {
		a.Status = StatusEnded
		return false
	}
	if bidder == a.Seller {
		return false
	}
	minRequired := a.MinBid
	if a.HighestBid > 0 {
		minRequired = a.HighestBid + 1
	}
	if amount < minRequired {
		return false
	}
	// refund previous highest bidder
	if a.HighestBid > 0 {
		h.refunds[a.HighestBidder] += a.HighestBid
	}
	a.HighestBid = amount
	a.HighestBidder = bidder
	a.BidCount++
	// anti-snipe: extend by 10 blocks if bid lands in final 10 blocks
	if a.EndHeight-h.currentHeight < 10 {
		a.EndHeight = h.currentHeight + 10
	}
	return true
}

func (h *House) EndAuction(auctionID string) bool {
	a, ok := h.auctions[auctionID]
	if !ok || a.Status != StatusActive {
		return false
	}
	if h.currentHeight < a.EndHeight {
		return false
	}
	a.Status = StatusEnded
	return true
}

func (h *House) Finalize(auctionID string) (seller string, amount int64, ok bool) {
	a, exists := h.auctions[auctionID]
	if !exists || a.Status != StatusEnded {
		return "", 0, false
	}
	a.Status = StatusFinalized
	if a.HighestBid == 0 {
		return a.Seller, 0, true
	}
	return a.Seller, a.HighestBid, true
}

func (h *House) CancelAuction(auctionID, caller string) bool {
	a, ok := h.auctions[auctionID]
	if !ok || a.Status != StatusActive {
		return false
	}
	if caller != a.Seller && caller != h.admin {
		return false
	}
	if a.HighestBid > 0 {
		h.refunds[a.HighestBidder] += a.HighestBid
	}
	a.Status = StatusCancelled
	return true
}

func (h *House) Withdraw(addr string) int64 {
	amt := h.refunds[addr]
	if amt > 0 {
		h.refunds[addr] = 0
	}
	return amt
}

func (h *House) GetAuction(id string) (*Auction, bool) {
	a, ok := h.auctions[id]
	return a, ok
}

func (h *House) RefundBalance(addr string) int64 {
	return h.refunds[addr]
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	s := string(buf[i:])
	if neg {
		s = "-" + s
	}
	return s
}

// package-level singleton house + exported render/entry points for the realm

var house = NewHouse("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")

func Tick(height int64) {
	house.Tick(height)
}

func CreateAuction(seller, item string, minBid, durationBlocks int64) string {
	id, ok := house.CreateAuction(seller, item, minBid, durationBlocks)
	if !ok {
		return ""
	}
	return id
}

func Bid(auctionID, bidder string, amount int64) bool {
	return house.Bid(auctionID, bidder, amount)
}

func EndAuction(auctionID string) bool {
	return house.EndAuction(auctionID)
}

func Finalize(auctionID string) string {
	seller, amount, ok := house.Finalize(auctionID)
	if !ok {
		return "not finalizable"
	}
	return seller + ":" + itoa(amount)
}

func CancelAuction(auctionID, caller string) bool {
	return house.CancelAuction(auctionID, caller)
}

func Withdraw(addr string) int64 {
	return house.Withdraw(addr)
}

func Render(path string) string {
	if path == "" {
		return "AuctionHouse realm — use CreateAuction, Bid, EndAuction, Finalize, Withdraw"
	}
	a, ok := house.GetAuction(path)
	if !ok {
		return "auction not found: " + path
	}
	return "Item: " + a.Item + " | Highest: " + itoa(a.HighestBid) + " by " + a.HighestBidder
}
