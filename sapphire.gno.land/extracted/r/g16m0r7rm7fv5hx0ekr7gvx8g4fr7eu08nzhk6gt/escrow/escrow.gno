package escrow

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Status represents the lifecycle of an escrow deal.
type Status int

const (
	StatusFunded Status = iota
	StatusReleased
	StatusRefunded
	StatusDisputed
	StatusResolved
)

func (s Status) String() string {
	switch s {
	case StatusFunded:
		return "funded"
	case StatusReleased:
		return "released"
	case StatusRefunded:
		return "refunded"
	case StatusDisputed:
		return "disputed"
	case StatusResolved:
		return "resolved"
	default:
		return "unknown"
	}
}

// Deal is a generic two-party escrow with an optional arbiter for disputes.
type Deal struct {
	ID       int64
	Buyer    address
	Seller   address
	Arbiter  address // address("") if none configured
	Amount   int64
	Status   Status
	CreatedAt int64
}

var (
	deals  *avl.Tree // id (string) -> *Deal
	nextID int64
)

func init() {
	deals = avl.NewTree()
	nextID = 1
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("escrow: must be a direct user call")
	}
	return cur.Previous().Address()
}

func idKey(id int64) string {
	return ufmt.Sprintf("%020d", id)
}

func getDeal(id int64) *Deal {
	key := idKey(id)
	if !deals.Has(key) {
		panic("escrow: deal not found")
	}
	raw := deals.Get(key)
	return raw.(*Deal)
}

// CreateDeal opens a new escrow, funded by the buyer, for a given seller.
// An optional arbiter can be set to resolve disputes; pass address("") for none.
func CreateDeal(cur realm, seller address, arbiter address) int64 {
	caller := assertUserCall(cur)
	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("escrow: must fund the deal with ugnot")
	}
	if seller == caller {
		panic("escrow: buyer and seller must differ")
	}

	id := nextID
	nextID++

	deals.Set(idKey(id), &Deal{
		ID:        id,
		Buyer:     caller,
		Seller:    seller,
		Arbiter:   arbiter,
		Amount:    amount,
		Status:    StatusFunded,
		CreatedAt: runtime.ChainHeight(),
	})
	return id
}

// Release lets the buyer release funds to the seller once satisfied.
func Release(cur realm, id int64) {
	caller := assertUserCall(cur)
	d := getDeal(id)
	if d.Status != StatusFunded {
		panic("escrow: deal is not in fundable state")
	}
	if caller != d.Buyer {
		panic("escrow: only the buyer can release funds")
	}

	payout(cur, d, d.Seller)
	d.Status = StatusReleased
}

// RequestRefund lets the seller voluntarily refund the buyer (e.g. cannot fulfill).
func RequestRefund(cur realm, id int64) {
	caller := assertUserCall(cur)
	d := getDeal(id)
	if d.Status != StatusFunded {
		panic("escrow: deal is not in fundable state")
	}
	if caller != d.Seller {
		panic("escrow: only the seller can initiate a refund")
	}

	payout(cur, d, d.Buyer)
	d.Status = StatusRefunded
}

// Dispute lets either party flag the deal for arbiter review.
func Dispute(cur realm, id int64) {
	caller := assertUserCall(cur)
	d := getDeal(id)
	if d.Status != StatusFunded {
		panic("escrow: deal is not in fundable state")
	}
	if caller != d.Buyer && caller != d.Seller {
		panic("escrow: only buyer or seller can dispute")
	}
	if d.Arbiter == address("") {
		panic("escrow: no arbiter configured for this deal")
	}
	d.Status = StatusDisputed
}

// ResolveDispute lets the configured arbiter decide the outcome.
func ResolveDispute(cur realm, id int64, payToSeller bool) {
	caller := assertUserCall(cur)
	d := getDeal(id)
	if d.Status != StatusDisputed {
		panic("escrow: deal is not under dispute")
	}
	if caller != d.Arbiter {
		panic("escrow: only the arbiter can resolve")
	}

	if payToSeller {
		payout(cur, d, d.Seller)
	} else {
		payout(cur, d, d.Buyer)
	}
	d.Status = StatusResolved
}

func payout(cur realm, d *Deal, to address) {
	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	have := bk.GetCoins(realmAddr).AmountOf("ugnot")
	amount := d.Amount
	if amount > have {
		amount = have
	}
	if amount > 0 {
		bk.SendCoins(realmAddr, to, chain.Coins{chain.NewCoin("ugnot", amount)})
	}
}

func Render(path string) string {
	out := "# Escrow\n\n"
	out += ufmt.Sprintf("Total deals: %d\n\n", deals.Size())
	deals.Iterate("", "", func(key string, value interface{}) bool {
		d := value.(*Deal)
		out += ufmt.Sprintf("## #%d\n", d.ID)
		out += ufmt.Sprintf("Buyer: %s | Seller: %s | Amount: %d ugnot | Status: %s\n\n",
			d.Buyer, d.Seller, d.Amount, d.Status.String())
		return false
	})
	return out
}
