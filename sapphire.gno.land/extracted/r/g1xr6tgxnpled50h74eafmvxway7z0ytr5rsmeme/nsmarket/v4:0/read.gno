package nsmarket

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// Reads for the site. Rows are ";"-separated records of
// "label*domain,price,seller,listed,live" where `live` is false when the
// listing has gone stale under it — the seller moved the name, let it
// lapse, or revoked permission.
//
// Stale listings are REPORTED, not hidden and not silently deleted.
// Hiding them makes a seller's page lie about what they have up; and
// deleting them would mean a read function writing to storage, which is
// how a query starts costing gas.

func row(tid string, l *Listing) string {
	label, domainLabel := splitTokenID(tid)
	live := nsdata.NameExists(label, domainLabel) &&
		nsdata.GetNameOwner(label, domainLabel) == l.seller &&
		nsdata.IsNameValid(label, domainLabel)
	return ufmt.Sprintf("%s,%d,%s,%d,%t", tid, l.price, l.seller.String(), l.listed, live)
}

// GetListing returns one row, or "" when nothing is listed.
func GetListing(tid string) string {
	l := get(tid)
	if l == nil {
		return ""
	}
	return row(tid, l)
}

// ListForSale pages through everything on offer, cheapest first within a
// page. `after` is the last token id of the previous page.
func ListForSale(after string, limit int) (rows, next string) {
	if limit <= 0 || limit > maxPage {
		limit = maxPage
	}
	var out []string
	var last string
	listings.Iterate(after, "", func(key string, v any) bool {
		if key == after {
			return false // the cursor is exclusive
		}
		out = append(out, row(key, v.(*Listing)))
		last = key
		return len(out) >= limit
	})
	if len(out) < limit {
		last = "" // the end; no cursor to hand back
	}
	return strings.Join(out, ";"), last
}

// ListingsBy is everything one wallet has up for sale. Walks the whole
// tree because listings are keyed by token id, not by seller: a second
// index would be a second thing to keep correct and a second thing the
// seller pays storage for, to save a walk over a list that is small by
// construction.
func ListingsBy(seller address) string {
	var out []string
	listings.Iterate("", "", func(key string, v any) bool {
		l := v.(*Listing)
		if l.seller == seller {
			out = append(out, row(key, l))
		}
		return false
	})
	return strings.Join(out, ";")
}

func CountListed() int64 { return int64(listings.Size()) }
func CountSold() int64   { return sold }

// Quote is what a buyer pays and what the seller receives, before
// anybody signs anything. The fee is read live, so this is the same
// arithmetic Buy will do rather than a copy of it that can drift.
func Quote(tid string) (price, fee, toSeller int64) {
	l := get(tid)
	if l == nil {
		return 0, 0, 0
	}
	f, s := FeeFor(l.price)
	return l.price, f, s
}

// Version lets the site tell which shape it is talking to without
// guessing from a function signature.
func Version() string { return "v1" }
