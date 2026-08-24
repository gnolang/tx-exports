package splitpayment

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Payee is a recipient with a share expressed in basis points (1/100 of a percent).
type Payee struct {
	Addr    address
	ShareBp int64 // basis points, all payees must sum to 10000
}

// Splitter is a payment group: any funds sent to Distribute are divided
// among the configured payees according to their shares.
type Splitter struct {
	ID       int64
	Owner    address
	Payees   []Payee
	TotalIn  int64
	TotalOut *avl.Tree // addr -> int64, cumulative amount paid to each payee
}

var (
	splitters *avl.Tree // id (string) -> *Splitter
	nextID    int64
)

func init() {
	splitters = avl.NewTree()
	nextID = 1
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("splitpayment: must be a direct user call")
	}
	return cur.Previous().Address()
}

func idKey(id int64) string {
	return ufmt.Sprintf("%020d", id)
}

func getSplitter(id int64) *Splitter {
	key := idKey(id)
	if !splitters.Has(key) {
		panic("splitpayment: splitter not found")
	}
	raw := splitters.Get(key)
	return raw.(*Splitter)
}

// CreateSplitter defines a new payee group. Shares (in basis points) must sum to 10000.
func CreateSplitter(cur realm, addr0 address, bp0 int64, addr1 address, bp1 int64, addr2 address, bp2 int64, addr3 address, bp3 int64) int64 {
	caller := assertUserCall(cur)

	payees := []Payee{}
	candidates := []Payee{
		{Addr: addr0, ShareBp: bp0},
		{Addr: addr1, ShareBp: bp1},
		{Addr: addr2, ShareBp: bp2},
		{Addr: addr3, ShareBp: bp3},
	}
	var total int64
	for _, p := range candidates {
		if p.Addr != address("") && p.ShareBp > 0 {
			payees = append(payees, p)
			total += p.ShareBp
		}
	}
	if len(payees) < 2 {
		panic("splitpayment: at least 2 payees required")
	}
	if total != 10000 {
		panic("splitpayment: shares must sum to exactly 10000 basis points")
	}

	id := nextID
	nextID++

	splitters.Set(idKey(id), &Splitter{
		ID:       id,
		Owner:    caller,
		Payees:   payees,
		TotalOut: avl.NewTree(),
	})
	return id
}

// Distribute accepts a ugnot payment and immediately splits it among payees
// proportional to their configured shares. Remainder from integer division
// goes to the first payee.
func Distribute(cur realm, id int64) {
	assertUserCall(cur)
	s := getSplitter(id)

	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("splitpayment: must send ugnot to distribute")
	}
	s.TotalIn += amount

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	var distributed int64
	for i, p := range s.Payees {
		var share int64
		if i == len(s.Payees)-1 {
			share = amount - distributed // give remainder to last payee
		} else {
			share = amount * p.ShareBp / 10000
			distributed += share
		}
		if share > 0 {
			bk.SendCoins(realmAddr, p.Addr, chain.Coins{chain.NewCoin("ugnot", share)})
			key := string(p.Addr)
			existing := int64(0)
			if s.TotalOut.Has(key) {
				existing = s.TotalOut.Get(key).(int64)
			}
			s.TotalOut.Set(key, existing+share)
		}
	}
}

func Render(path string) string {
	out := "# Split Payment\n\n"
	out += ufmt.Sprintf("Total splitters: %d\n\n", splitters.Size())
	splitters.Iterate("", "", func(key string, value interface{}) bool {
		s := value.(*Splitter)
		out += ufmt.Sprintf("## #%d | Total in: %d ugnot\n", s.ID, s.TotalIn)
		for _, p := range s.Payees {
			out += ufmt.Sprintf("- %s: %d bp\n", p.Addr, p.ShareBp)
		}
		out += "\n"
		return false
	})
	return out
}
