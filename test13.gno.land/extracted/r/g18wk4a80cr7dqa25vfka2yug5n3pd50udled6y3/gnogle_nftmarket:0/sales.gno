package gnogle_nftmarket

import (
	"chain/runtime"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// Sale is one settled trade, kept in a bounded on-chain history so the UI can
// show recent activity and compute volume without scanning events.
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

// recordSale appends a settled trade, keeping only the most recent 200.
func recordSale(collID, tokenID string, from, to address, price int64, kind string) {
	sales = append(sales, &Sale{collID, tokenID, from, to, price, kind, runtime.ChainHeight()})
	if len(sales) > 200 {
		sales = sales[len(sales)-200:]
	}
}

// SalesJSON returns the most recent sales, newest first, up to limit (default 50).
func SalesJSON(limit int) string {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	var b strings.Builder
	b.WriteString("[")
	n := 0
	for i := len(sales) - 1; i >= 0 && n < limit; i-- {
		s := sales[i]
		if n > 0 {
			b.WriteString(",")
		}
		b.WriteString(ufmt.Sprintf(
			`{"collID":%s,"tokenID":%s,"from":%s,"to":%s,"price":%d,"kind":%s,"height":%d}`,
			js(s.collID), js(s.tokenID), js(s.from.String()), js(s.to.String()), s.price, js(s.kind), s.height))
		n++
	}
	b.WriteString("]")
	return b.String()
}
