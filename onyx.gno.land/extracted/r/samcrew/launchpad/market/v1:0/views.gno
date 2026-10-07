package market

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/samcrew/launchpad/meta/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/samcrew/launchpad/config/v1"
	"gno.land/r/samcrew/launchpad/nft/v1"
)

func num(n int64) string { return meta.JSONString(strconv.FormatInt(n, 10)) }

// splitJSON is how a price would be divided at a protocol fee: what the
// seller keeps, the treasury's fee and each royalty.
func splitJSON(collection string, price, feeBPS int64) string {
	fee := sm.BPS(price, feeBPS)
	seller := sm.Sub(price, fee)
	var b strings.Builder
	for i, r := range nft.RoyaltyQuote(collection, price) {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(`{"account":` + meta.JSONString(r.Account.String()) +
			`,"amount":` + num(r.Amount) + "}")
		seller = sm.Sub(seller, r.Amount)
	}
	return `{"seller":` + num(seller) + `,"fee":` + num(fee) +
		`,"royalties":[` + b.String() + "]}"
}

func listingJSON(l *Listing) string {
	return "{" +
		`"id":` + meta.JSONString(l.ID) +
		`,"collection":` + meta.JSONString(l.Collection) +
		`,"number":` + num(l.Number) +
		`,"seller":` + meta.JSONString(l.Seller.String()) +
		`,"price":` + num(l.Price) +
		`,"currency":` + meta.JSONString(l.Currency) +
		`,"createdAt":` + num(l.CreatedAt) +
		`,"expiresAt":` + num(l.ExpiresAt) +
		`,"feeBPS":` + num(l.FeeBPS) +
		`,"buyable":` + strconv.FormatBool(live(l)) +
		`,"split":` + splitJSON(l.Collection, l.Price, l.FeeBPS) + "}"
}

func offerJSON(o *Offer) string {
	return "{" +
		`"id":` + meta.JSONString(o.ID) +
		`,"kind":` + meta.JSONString(o.Kind) +
		`,"collection":` + meta.JSONString(o.Collection) +
		`,"number":` + num(o.Number) +
		`,"trait":` + meta.JSONString(o.Trait) +
		`,"buyer":` + meta.JSONString(o.Buyer.String()) +
		`,"price":` + num(o.Price) +
		`,"currency":` + meta.JSONString(o.Currency) +
		`,"createdAt":` + num(o.CreatedAt) +
		`,"expiresAt":` + num(o.ExpiresAt) +
		`,"feeBPS":` + num(o.FeeBPS) +
		`,"split":` + splitJSON(o.Collection, o.Price, o.FeeBPS) + "}"
}

// ListingJSON is an open listing, or "null" once it is closed.
func ListingJSON(id string) string {
	if l := findListing(id); l != nil {
		return listingJSON(l)
	}
	return "null"
}

// OfferJSON is an open offer, or "null" once it is closed. An open offer can
// be past its expiry: it then only waits for its refund.
func OfferJSON(id string) string {
	if o, _ := findOffer(id); o != nil {
		return offerJSON(o)
	}
	return "null"
}

// Lists are read in slices of 1 to maxSlice entries that start after a
// cursor: what identifies the last entry already read, or nothing to start
// from the beginning. Orders come and go between two reads, and a cursor
// never skips or repeats one that stayed. A slice costs the same wherever it
// starts.
const maxSlice = 50

// sliceJSON renders up to size entries of tree whose keys lie in [from, to),
// in key order, or from the last key down when reverse.
func sliceJSON(tree *avl.Tree, from, to string, reverse bool, size int64, render func(v any) string) string {
	if size < 1 || size > maxSlice {
		panic("launchpad/market: invalid slice size")
	}
	var b strings.Builder
	b.WriteByte('[')
	visit := func(_ string, v any) bool {
		if b.Len() > 1 {
			b.WriteByte(',')
		}
		b.WriteString(render(v))
		size--
		return size == 0
	}
	if reverse {
		tree.ReverseIterate(from, to, visit)
	} else {
		tree.Iterate(from, to, visit)
	}
	b.WriteByte(']')
	return b.String()
}

// cursorKey reads an order cursor: the ID of the last order already read.
func cursorKey(prefix byte, cursor string) seqid.ID {
	key, ok := orderKey(prefix, cursor)
	if !ok {
		panic("launchpad/market: invalid cursor")
	}
	n, _ := seqid.FromString(key)
	return n
}

// after is the first key an oldest-first slice may hold: the one following
// the cursor, or "" with no cursor.
func after(prefix byte, cursor string) string {
	if cursor == "" {
		return ""
	}
	return (cursorKey(prefix, cursor) + 1).String()
}

// below is the last key a newest-first slice may hold: the one preceding the
// cursor, or "" with no cursor. No order has key zero, so the first order's
// ID leaves nothing below it.
func below(prefix byte, cursor string) string {
	if cursor == "" {
		return ""
	}
	return (cursorKey(prefix, cursor) - 1).String()
}

func renderListing(v any) string { return listingJSON(v.(*Listing)) }
func renderOffer(v any) string   { return offerJSON(v.(*Offer)) }

// ListingsJSON reads every open listing, newest first, starting below the
// listing ID before ("" starts from the newest).
func ListingsJSON(before string, size int64) string {
	// A descending range includes its upper bound.
	return sliceJSON(&listings, "", below('L', before), true, size, renderListing)
}

// CollectionListingsJSON reads a collection's open listings in token number
// order, starting after the token number afterNumber (0 starts from the
// first).
func CollectionListingsJSON(collection string, afterNumber, size int64) string {
	if afterNumber < 0 {
		panic("launchpad/market: invalid cursor")
	}
	// "0" is the byte after "/": the range ends with this collection's keys.
	return sliceJSON(&listed, tokenKey(collection, sm.Add(afterNumber, 1)), collection+"0", false, size, renderListing)
}

// account checks an address argument of a view.
func account(who string) string {
	if !meta.ValidAddress(address(who)) {
		panic("launchpad/market: invalid account")
	}
	return who
}

// SellerListingsJSON reads an account's open listings, oldest first, starting
// after the listing ID afterID ("" starts from the oldest).
func SellerListingsJSON(seller, afterID string, size int64) string {
	return sliceJSON(&bySeller, account(seller)+"/"+after('L', afterID), seller+"0", false, size, renderListing)
}

// OffersJSON reads every open offer, newest first, starting below the offer
// ID before ("" starts from the newest).
func OffersJSON(before string, size int64) string {
	return sliceJSON(&offers, "", below('O', before), true, size, renderOffer)
}

// CollectionOffersJSON reads a collection's open offers of every kind, oldest
// first, starting after the offer ID afterID ("" starts from the oldest).
func CollectionOffersJSON(collection, afterID string, size int64) string {
	return sliceJSON(&open, collection+"/"+after('O', afterID), collection+"0", false, size, renderOffer)
}

// BuyerOffersJSON reads an account's open offers, oldest first, starting
// after the offer ID afterID ("" starts from the oldest).
func BuyerOffersJSON(buyer, afterID string, size int64) string {
	return sliceJSON(&byBuyer, account(buyer)+"/"+after('O', afterID), buyer+"0", false, size, renderOffer)
}

// TokenListingJSON is the open listing of a token, or "null".
func TokenListingJSON(collection string, number int64) string {
	if l := listingOf(collection, number); l != nil {
		return listingJSON(l)
	}
	return "null"
}

// TermsJSON is what a sale costs now: the protocol fee a new listing would
// pin, and how a price would split for the collection. A fee of
// -1 means the lane is closed; config's ActionStatusJSON tells whether the
// market lane accepts new orders right now.
func TermsJSON(collection string, price int64) string {
	p := config.GetVersion(config.GetCurrentVersion())
	split := "null"
	if p.NFTSecondaryFeeBPS >= 0 && p.NFTSecondaryFeeBPS <= maxSecondaryFeeBPS {
		split = splitJSON(collection, price, p.NFTSecondaryFeeBPS)
	}
	return "{" +
		`"feeBPS":` + num(p.NFTSecondaryFeeBPS) +
		`,"maxFeeBPS":` + num(maxSecondaryFeeBPS) +
		`,"treasury":` + meta.JSONString(p.Treasury.String()) +
		`,"split":` + split + "}"
}
