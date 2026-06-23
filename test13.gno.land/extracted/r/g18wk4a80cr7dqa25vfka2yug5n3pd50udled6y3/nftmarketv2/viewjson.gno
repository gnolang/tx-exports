package nftmarket

// JSON read helpers for front-ends. These return compact JSON strings so a web
// client can fetch a whole view in a single vm/qeval call instead of parsing
// Gno tuple output. They are read-only.

import (
	"strconv"
	"strings"

	"gno.land/p/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/grc721"
	"gno.land/p/nt/ufmt/v0"
)

// CollectionsJSON returns every collection as a JSON array.
func CollectionsJSON() string {
	var b strings.Builder
	b.WriteString("[")
	for i, id := range collOrder {
		v, ok := collections.Get(id)
		if !ok {
			continue
		}
		c := v.(*Collection)
		if i > 0 {
			b.WriteString(",")
		}
		b.WriteString(ufmt.Sprintf(
			`{"id":%s,"name":%s,"symbol":%s,"creator":%s,"baseURI":%s,"mintPrice":%d,"maxSupply":%d,"minted":%d,"royaltyBps":%d}`,
			js(c.id), js(c.name), js(c.symbol), js(c.creator.String()), js(c.baseURI),
			c.mintPrice, c.maxSupply, c.minted, c.royaltyBps))
	}
	b.WriteString("]")
	return b.String()
}

// TokensJSON returns every minted token of a collection with its market state.
func TokensJSON(collID string) string {
	coll := mustGetCollection(collID)
	var b strings.Builder
	b.WriteString("[")
	first := true
	for i := int64(1); i <= coll.minted; i++ {
		tokenID := strconv.FormatInt(i, 10)
		owner, err := coll.nft.OwnerOf(grc721.TokenID(tokenID))
		if err != nil {
			continue
		}
		if !first {
			b.WriteString(",")
		}
		first = false

		listed, price, seller := false, int64(0), ""
		if l, ok := getListing(collID, tokenID); ok {
			listed, price, seller = true, l.price, l.seller.String()
		}
		auction, minBid, highBid, highBidder, endUnix := false, int64(0), int64(0), "", int64(0)
		if a, ok := getAuction(collID, tokenID); ok {
			auction, minBid, highBid, highBidder, endUnix = true, a.minBid, a.highestBid, a.highestBidder.String(), a.endTime.Unix()
		}

		b.WriteString(ufmt.Sprintf(
			`{"id":%s,"owner":%s,"listed":%s,"price":%d,"seller":%s,"auction":%s,"minBid":%d,"highBid":%d,"highBidder":%s,"endUnix":%d}`,
			js(tokenID), js(owner.String()), jb(listed), price, js(seller),
			jb(auction), minBid, highBid, js(highBidder), endUnix))
	}
	b.WriteString("]")
	return b.String()
}

// OffersJSON returns the standing offers on a token.
func OffersJSON(collID, tokenID string) string {
	prefix := collID + "/" + tokenID + "/"
	var b strings.Builder
	b.WriteString("[")
	first := true
	offers.Iterate("", "", func(key string, value any) bool {
		if !strings.HasPrefix(key, prefix) {
			return false
		}
		o := value.(*Offer)
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

// js encodes a string as a JSON string literal.
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

func jb(v bool) string {
	if v {
		return "true"
	}
	return "false"
}
