package escrow

type DealStatus int

const (
	DealFunded DealStatus = iota
	DealBuyerApproved
	DealSellerApproved
	DealReleased
	DealDisputed
	DealResolved
	DealRefunded
)

type Deal struct {
	ID            string
	Buyer         string
	Seller        string
	Arbiter       string
	Amount        int64
	Status        DealStatus
	BuyerApprove  bool
	SellerApprove bool
	CreatedHeight int64
}

type Escrow struct {
	admin         string
	deals         map[string]*Deal
	nextSeq       int64
	currentHeight int64
}

func NewEscrow(admin string) *Escrow {
	return &Escrow{admin: admin, deals: make(map[string]*Deal)}
}

func (e *Escrow) Tick(height int64) {
	if height > e.currentHeight {
		e.currentHeight = height
	}
}

func (e *Escrow) CreateDeal(buyer, seller, arbiter string, amount int64) (string, bool) {
	if buyer == "" || seller == "" || amount <= 0 || buyer == seller {
		return "", false
	}
	e.nextSeq++
	id := itoa(e.nextSeq)
	e.deals[id] = &Deal{
		ID:            id,
		Buyer:         buyer,
		Seller:        seller,
		Arbiter:       arbiter,
		Amount:        amount,
		Status:        DealFunded,
		CreatedHeight: e.currentHeight,
	}
	return id, true
}

func (e *Escrow) Approve(caller, dealID string) bool {
	d, ok := e.deals[dealID]
	if !ok || d.Status != DealFunded {
		return false
	}
	if caller == d.Buyer {
		d.BuyerApprove = true
	} else if caller == d.Seller {
		d.SellerApprove = true
	} else {
		return false
	}
	if d.BuyerApprove && d.SellerApprove {
		d.Status = DealReleased
	}
	return true
}

func (e *Escrow) Release(caller, dealID string) bool {
	d, ok := e.deals[dealID]
	if !ok || d.Status != DealFunded {
		return false
	}
	if caller != d.Buyer {
		return false
	}
	d.Status = DealReleased
	return true
}

func (e *Escrow) Dispute(caller, dealID string) bool {
	d, ok := e.deals[dealID]
	if !ok || d.Status != DealFunded {
		return false
	}
	if caller != d.Buyer && caller != d.Seller {
		return false
	}
	if d.Arbiter == "" {
		return false
	}
	d.Status = DealDisputed
	return true
}

// Resolve lets the arbiter decide the outcome: toSeller true pays seller, false refunds buyer.
func (e *Escrow) Resolve(arbiter, dealID string, toSeller bool) bool {
	d, ok := e.deals[dealID]
	if !ok || d.Status != DealDisputed || arbiter != d.Arbiter {
		return false
	}
	if toSeller {
		d.Status = DealResolved
	} else {
		d.Status = DealRefunded
	}
	return true
}

func (e *Escrow) Payout(dealID string) (recipient string, amount int64, ok bool) {
	d, exists := e.deals[dealID]
	if !exists {
		return "", 0, false
	}
	switch d.Status {
	case DealReleased, DealResolved:
		return d.Seller, d.Amount, true
	case DealRefunded:
		return d.Buyer, d.Amount, true
	default:
		return "", 0, false
	}
}

func (e *Escrow) GetDeal(id string) (*Deal, bool) {
	d, ok := e.deals[id]
	return d, ok
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

var escrow = NewEscrow("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")

func Tick(height int64) {
	escrow.Tick(height)
}

func CreateDeal(buyer, seller, arbiter string, amount int64) string {
	id, ok := escrow.CreateDeal(buyer, seller, arbiter, amount)
	if !ok {
		return ""
	}
	return id
}

func Approve(caller, dealID string) bool {
	return escrow.Approve(caller, dealID)
}

func Release(caller, dealID string) bool {
	return escrow.Release(caller, dealID)
}

func Dispute(caller, dealID string) bool {
	return escrow.Dispute(caller, dealID)
}

func Resolve(arbiter, dealID string, toSeller bool) bool {
	return escrow.Resolve(arbiter, dealID, toSeller)
}

func Payout(dealID string) string {
	recipient, amount, ok := escrow.Payout(dealID)
	if !ok {
		return "not payable"
	}
	return recipient + ":" + itoa(amount)
}

func Render(path string) string {
	if path == "" {
		return "Escrow realm — use CreateDeal, Approve, Release, Dispute, Resolve"
	}
	d, ok := escrow.GetDeal(path)
	if !ok {
		return "deal not found: " + path
	}
	return "Buyer: " + d.Buyer + " | Seller: " + d.Seller + " | Amount: " + itoa(d.Amount)
}
