package gnogle_market

import "chain/runtime"

// Sale is one settled trade, kept in a bounded on-chain history.
type Sale struct {
	collID  string
	tokenID string
	from    address
	to      address
	price   int64
	kind    string // "buy" | "offer" | "auction"
	height  int64
}

var sales []*Sale

func recordSale(collID, tokenID string, from, to address, price int64, kind string) {
	sales = append(sales, &Sale{collID, tokenID, from, to, price, kind, runtime.ChainHeight()})
	if len(sales) > 200 {
		sales = sales[len(sales)-200:]
	}
}
