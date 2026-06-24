package gnogle_market2

import (
	"chain"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// MarketAddress returns this market realm's address — the address users approve
// on gnogle_nft (SetApprovalForAll) to enable trading.
func MarketAddress() string {
	return chain.PackageAddress("gno.land/r/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/gnogle_market2").String()
}

// ListingsJSON returns all active fixed-price listings.
func ListingsJSON() string {
	var b strings.Builder
	b.WriteString("[")
	first := true
	listings.Iterate("", "", func(_ string, v any) bool {
		l := v.(*Listing)
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(ufmt.Sprintf(`{"collID":%s,"tokenID":%s,"seller":%s,"price":%d}`,
			js(l.collID), js(l.tokenID), js(l.seller.String()), l.price))
		return false
	})
	b.WriteString("]")
	return b.String()
}

// AuctionsJSON returns all active auctions.
func AuctionsJSON() string {
	var b strings.Builder
	b.WriteString("[")
	first := true
	auctions.Iterate("", "", func(_ string, v any) bool {
		a := v.(*Auction)
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(ufmt.Sprintf(
			`{"collID":%s,"tokenID":%s,"seller":%s,"minBid":%d,"highBid":%d,"highBidder":%s,"endUnix":%d}`,
			js(a.collID), js(a.tokenID), js(a.seller.String()), a.minBid, a.highestBid, js(a.highestBidder.String()), a.endTime.Unix()))
		return false
	})
	b.WriteString("]")
	return b.String()
}

// AllOffersJSON returns every standing offer.
func AllOffersJSON() string {
	var b strings.Builder
	b.WriteString("[")
	first := true
	offers.Iterate("", "", func(_ string, v any) bool {
		o := v.(*Offer)
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(ufmt.Sprintf(`{"collID":%s,"tokenID":%s,"buyer":%s,"amount":%d}`,
			js(o.collID), js(o.tokenID), js(o.buyer.String()), o.amount))
		return false
	})
	b.WriteString("]")
	return b.String()
}

// OffersJSON returns the offers on a single token.
func OffersJSON(collID, tokenID string) string {
	prefix := collID + "/" + tokenID + "/"
	var b strings.Builder
	b.WriteString("[")
	first := true
	offers.Iterate("", "", func(k string, v any) bool {
		if !strings.HasPrefix(k, prefix) {
			return false
		}
		o := v.(*Offer)
		if !first {
			b.WriteString(",")
		}
		first = false
		b.WriteString(ufmt.Sprintf(`{"buyer":%s,"amount":%d}`, js(o.buyer.String()), o.amount))
		return false
	})
	b.WriteString("]")
	return b.String()
}

// SalesJSON returns recent sales, newest first, up to limit (default 50).
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

func js(s string) string {
	var b strings.Builder
	b.WriteString(`"`)
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			b.WriteString(string(r))
		}
	}
	b.WriteString(`"`)
	return b.String()
}
