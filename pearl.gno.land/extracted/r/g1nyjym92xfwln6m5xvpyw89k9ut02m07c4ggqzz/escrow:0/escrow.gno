package escrow

import "strconv"

type Escrow struct {
	Buyer   string
	Seller  string
	Amount  int64
	Release bool
}

var deals map[string]*Escrow

func init() {
	deals = make(map[string]*Escrow)
}

func Create(id, buyer, seller string, amount int64) {
	if amount <= 0 {
		panic("invalid amount")
	}
	deals[id] = &Escrow{
		Buyer:  buyer,
		Seller: seller,
		Amount: amount,
	}
}

func ReleaseFunds(id, caller string) {
	d, ok := deals[id]
	if !ok {
		panic("deal not found")
	}
	if caller != d.Buyer {
		panic("only buyer can release")
	}
	d.Release = true
}

func GetDeal(id string) (string, string, int64, bool) {
	d := deals[id]
	return d.Buyer, d.Seller, d.Amount, d.Release
}

func Render(_ string) string {
	out := "escrow deals:\n"
	for id, d := range deals {
		status := "pending"
		if d.Release {
			status = "released"
		}
		out += "  " + id + " (" + strconv.Itoa(int(d.Amount)) + ") " + status + "\n"
	}
	return out
}
