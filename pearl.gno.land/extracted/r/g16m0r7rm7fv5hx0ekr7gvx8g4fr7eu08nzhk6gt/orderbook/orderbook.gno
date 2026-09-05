package orderbook

type Side int

const (
	SideBuy Side = iota
	SideSell
)

type OrderStatus int

const (
	OrderOpen OrderStatus = iota
	OrderPartial
	OrderFilled
	OrderCancelled
)

type Order struct {
	ID          string
	Trader      string
	Side        Side
	Price       int64 // limit price
	Qty         int64
	Filled      int64
	Height      int64
	Status      OrderStatus
}

type Fill struct {
	BuyOrderID  string
	SellOrderID string
	Price       int64
	Qty         int64
	Height      int64
}

type Book struct {
	admin         string
	orders        map[string]*Order
	buyIDs        []string // open buy order ids, unsorted; matched by scan
	sellIDs       []string
	fills         []Fill
	nextSeq       int64
	currentHeight int64
}

func NewBook(admin string) *Book {
	return &Book{admin: admin, orders: make(map[string]*Order)}
}

func (b *Book) Tick(height int64) {
	if height > b.currentHeight {
		b.currentHeight = height
	}
}

func remaining(o *Order) int64 {
	return o.Qty - o.Filled
}

// PlaceOrder submits a limit order and immediately attempts to match it
// against resting orders on the opposite side (price-then-time priority).
func (b *Book) PlaceOrder(trader string, side Side, price, qty int64) (string, bool) {
	if trader == "" || price <= 0 || qty <= 0 {
		return "", false
	}
	b.nextSeq++
	id := itoa(b.nextSeq)
	o := &Order{ID: id, Trader: trader, Side: side, Price: price, Qty: qty, Height: b.currentHeight, Status: OrderOpen}
	b.orders[id] = o

	if side == SideBuy {
		b.matchBuy(o)
		if remaining(o) > 0 {
			b.buyIDs = append(b.buyIDs, id)
		}
	} else {
		b.matchSell(o)
		if remaining(o) > 0 {
			b.sellIDs = append(b.sellIDs, id)
		}
	}
	b.settleStatus(o)
	return id, true
}

// matchBuy fills the incoming buy order against the best (lowest price, then earliest) resting sells.
func (b *Book) matchBuy(buy *Order) {
	for remaining(buy) > 0 {
		bestIdx := -1
		for i, sid := range b.sellIDs {
			s, ok := b.orders[sid]
			if !ok || remaining(s) <= 0 || s.Status == OrderCancelled {
				continue
			}
			if s.Price > buy.Price {
				continue
			}
			if bestIdx == -1 {
				bestIdx = i
				continue
			}
			best := b.orders[b.sellIDs[bestIdx]]
			if s.Price < best.Price || (s.Price == best.Price && s.Height < best.Height) {
				bestIdx = i
			}
		}
		if bestIdx == -1 {
			break
		}
		sell := b.orders[b.sellIDs[bestIdx]]
		qty := remaining(buy)
		if remaining(sell) < qty {
			qty = remaining(sell)
		}
		buy.Filled += qty
		sell.Filled += qty
		b.fills = append(b.fills, Fill{BuyOrderID: buy.ID, SellOrderID: sell.ID, Price: sell.Price, Qty: qty, Height: b.currentHeight})
		b.settleStatus(sell)
		if remaining(sell) == 0 {
			b.sellIDs = append(b.sellIDs[:bestIdx], b.sellIDs[bestIdx+1:]...)
		}
	}
}

func (b *Book) matchSell(sell *Order) {
	for remaining(sell) > 0 {
		bestIdx := -1
		for i, bid := range b.buyIDs {
			bo, ok := b.orders[bid]
			if !ok || remaining(bo) <= 0 || bo.Status == OrderCancelled {
				continue
			}
			if bo.Price < sell.Price {
				continue
			}
			if bestIdx == -1 {
				bestIdx = i
				continue
			}
			best := b.orders[b.buyIDs[bestIdx]]
			if bo.Price > best.Price || (bo.Price == best.Price && bo.Height < best.Height) {
				bestIdx = i
			}
		}
		if bestIdx == -1 {
			break
		}
		buy := b.orders[b.buyIDs[bestIdx]]
		qty := remaining(sell)
		if remaining(buy) < qty {
			qty = remaining(buy)
		}
		sell.Filled += qty
		buy.Filled += qty
		b.fills = append(b.fills, Fill{BuyOrderID: buy.ID, SellOrderID: sell.ID, Price: buy.Price, Qty: qty, Height: b.currentHeight})
		b.settleStatus(buy)
		if remaining(buy) == 0 {
			b.buyIDs = append(b.buyIDs[:bestIdx], b.buyIDs[bestIdx+1:]...)
		}
	}
}

func (b *Book) settleStatus(o *Order) {
	if o.Status == OrderCancelled {
		return
	}
	if remaining(o) == 0 {
		o.Status = OrderFilled
	} else if o.Filled > 0 {
		o.Status = OrderPartial
	} else {
		o.Status = OrderOpen
	}
}

func (b *Book) CancelOrder(caller, orderID string) bool {
	o, ok := b.orders[orderID]
	if !ok || (o.Status != OrderOpen && o.Status != OrderPartial) {
		return false
	}
	if caller != o.Trader && caller != b.admin {
		return false
	}
	o.Status = OrderCancelled
	b.removeFromBook(o)
	return true
}

func (b *Book) removeFromBook(o *Order) {
	if o.Side == SideBuy {
		for i, id := range b.buyIDs {
			if id == o.ID {
				b.buyIDs = append(b.buyIDs[:i], b.buyIDs[i+1:]...)
				break
			}
		}
	} else {
		for i, id := range b.sellIDs {
			if id == o.ID {
				b.sellIDs = append(b.sellIDs[:i], b.sellIDs[i+1:]...)
				break
			}
		}
	}
}

func (b *Book) GetOrder(id string) (*Order, bool) {
	o, ok := b.orders[id]
	return o, ok
}

func (b *Book) BestBid() int64 {
	var best int64 = -1
	for _, id := range b.buyIDs {
		o := b.orders[id]
		if remaining(o) > 0 && (best == -1 || o.Price > best) {
			best = o.Price
		}
	}
	return best
}

func (b *Book) BestAsk() int64 {
	var best int64 = -1
	for _, id := range b.sellIDs {
		o := b.orders[id]
		if remaining(o) > 0 && (best == -1 || o.Price < best) {
			best = o.Price
		}
	}
	return best
}

func (b *Book) FillCount() int {
	return len(b.fills)
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

// package-level singleton + exported entry points for the realm

var book = NewBook("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")

func Tick(height int64) {
	book.Tick(height)
}

func PlaceBuy(trader string, price, qty int64) string {
	id, ok := book.PlaceOrder(trader, SideBuy, price, qty)
	if !ok {
		return ""
	}
	return id
}

func PlaceSell(trader string, price, qty int64) string {
	id, ok := book.PlaceOrder(trader, SideSell, price, qty)
	if !ok {
		return ""
	}
	return id
}

func CancelOrder(caller, orderID string) bool {
	return book.CancelOrder(caller, orderID)
}

func BestBid() int64 {
	return book.BestBid()
}

func BestAsk() int64 {
	return book.BestAsk()
}

func FillCount() int {
	return book.FillCount()
}

func Render(path string) string {
	if path == "" {
		return "OrderBook realm — bid: " + itoa(book.BestBid()) + " | ask: " + itoa(book.BestAsk()) + " | fills: " + itoa(int64(book.FillCount()))
	}
	o, ok := book.GetOrder(path)
	if !ok {
		return "order not found: " + path
	}
	return "Trader: " + o.Trader + " | Price: " + itoa(o.Price) + " | Filled: " + itoa(o.Filled) + "/" + itoa(o.Qty)
}
