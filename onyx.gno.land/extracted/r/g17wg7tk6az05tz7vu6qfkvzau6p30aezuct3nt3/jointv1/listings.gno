package jointv1

import (
	"gno.land/p/nt/avl/v0"
	"gno.land/p/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/townmath"
)

// Player listings. A farm puts grain or hops up for sale at its own price;
// the goods leave its inventory into the listing (escrow). Pubs buy any part
// of a listing: the buyer pays qty * PriceCg, the seller receives that minus
// a ListingFeeBps fee, and the fee is destroyed (counted in the gold flow).
// The Town Farm's prices, ramp and daily limits do not apply. A listing that
// sells out or is cancelled is removed from the tree, so its storage deposit
// is refunded.

// Listing bounds and fee.
const (
	MinListingPriceCg int64 = 50   // per unit
	MaxListingPriceCg int64 = 2000 // per unit
	MaxListingQty     int64 = 200
	MaxOpenListings   int64 = 5 // per seller
	ListingFeeBps     int64 = 500
	maxListingsPage         = 50
	listingIDWidth          = 12
)

// Listing is one open offer: Qty units of Good at PriceCg centigold each.
type Listing struct {
	ID      uint64
	Seller  address
	Good    int
	Qty     int64
	PriceCg int64
}

var (
	listings      avl.Tree // listingKey(ID) -> *Listing
	nextListingID uint64   // the last ID given out (IDs start at 1)
)

// ListGoods puts qty (1 to 200) units of grain or hops from the caller's
// farm up for sale at priceCg (50 to 2000) centigold per unit. Farms only,
// at most MaxOpenListings open listings per farm. The farm is settled first,
// so the harvest so far counts. Direct user call only.
func ListGoods(cur realm, good int, qty, priceCg int64) {
	listGoods(userActor(cur), good, qty, priceCg)
}

func listGoods(actor address, good int, qty, priceCg int64) {
	assertNotPaused()
	assertGood(good)
	if good != GoodGrain && good != GoodHops {
		panic("town: grain and hops only")
	}
	if qty < 1 || qty > MaxListingQty {
		panic("town: listing quantity must be 1 to 200")
	}
	if priceCg < MinListingPriceCg || priceCg > MaxListingPriceCg {
		panic("town: listing price must be 50 to 2000 centigold")
	}
	t := mustTavern(actor.String())
	assertFarm(t)
	if t.OpenListings >= MaxOpenListings {
		panic("town: at most 5 open listings")
	}
	if nextListingID >= 999999999999 {
		panic("town: no listing ids left")
	}
	settleFarm(t)
	if t.Inv[good] < qty {
		panic("town: not enough stock")
	}
	nextListingID++
	listings.Set(listingKey(nextListingID), &Listing{
		ID:      nextListingID,
		Seller:  actor,
		Good:    good,
		Qty:     qty,
		PriceCg: priceCg,
	})
	t.Inv[good] -= qty
	t.OpenListings++
}

// BuyListing buys qty units (1 to what remains) of listing id. Pubs only.
// The buyer pays qty * PriceCg; the seller receives it minus the
// ListingFeeBps fee, which is destroyed. A listing that reaches 0 is
// removed. Direct user call only.
func BuyListing(cur realm, id uint64, qty int64) {
	buyListing(userActor(cur), id, qty)
}

func buyListing(actor address, id uint64, qty int64) {
	assertNotPaused()
	l := mustListing(id)
	t := mustTavern(actor.String())
	assertPub(t)
	if l.Seller == actor {
		panic("town: cannot buy your own listing")
	}
	if qty < 1 || qty > l.Qty {
		panic("town: quantity must be 1 to what the listing has left")
	}
	seller := mustTavern(l.Seller.String())
	settleTavern(t)
	if t.Inv[l.Good]+qty > MaxInv {
		panic("town: inventory full (max 1000 per good)")
	}
	total := qty * l.PriceCg // at most 200 * 2000
	if total > t.GoldCg {
		panic("town: not enough gold")
	}
	ownerActs(t)
	fee := townmath.MulBps(total, ListingFeeBps)
	t.GoldCg -= total
	t.ProfitTodayCg -= total
	t.SeasonProfitCg -= total
	seller.GoldCg += total - fee
	goldDestroyedCg += fee
	t.Inv[l.Good] += qty
	l.Qty -= qty
	if l.Qty == 0 {
		listings.Remove(listingKey(id))
		seller.OpenListings--
	}
}

// CancelListing closes the caller's listing id and returns what is left of
// it to the farm's inventory (aborts if that would pass FarmStorageCap). The
// farm is settled first. Seller only. Direct user call only.
func CancelListing(cur realm, id uint64) {
	cancelListing(userActor(cur), id)
}

func cancelListing(actor address, id uint64) {
	assertNotPaused()
	l := mustListing(id)
	if l.Seller != actor {
		panic("town: not your listing")
	}
	t := mustTavern(actor.String())
	settleFarm(t)
	// escrow comes back only within the farm's storage cap, so listing and
	// cancelling never stores more than a harvest could
	if t.Inv[l.Good]+l.Qty > FarmStorageCap {
		panic("town: inventory full (a farm stores at most 120 per good)")
	}
	t.Inv[l.Good] += l.Qty
	t.OpenListings--
	listings.Remove(listingKey(id))
}

// Listings returns up to count (clamped to 1..50) open listings from offset
// (at least 0), ordered by ID. Read-only.
func Listings(offset, count int) []Listing {
	if offset < 0 {
		offset = 0
	}
	if count < 1 {
		count = 1
	}
	if count > maxListingsPage {
		count = maxListingsPage
	}
	out := make([]Listing, 0, count)
	listings.IterateByOffset(offset, count, func(_ string, v any) bool {
		out = append(out, *(v.(*Listing)))
		return false
	})
	return out
}

// GetListing returns a copy of listing id and whether it is open. Read-only.
func GetListing(id uint64) (Listing, bool) {
	v := listings.Get(listingKey(id))
	if v == nil {
		return Listing{}, false
	}
	return *(v.(*Listing)), true
}

// ListingCount returns the number of open listings. Read-only.
func ListingCount() int {
	return listings.Size()
}

// OpenListings returns the number of open listings of seller (0 for an
// address with no business). Read-only.
func OpenListings(seller string) int {
	v := taverns.Get(seller)
	if v == nil {
		return 0
	}
	return int(v.(*Tavern).OpenListings)
}

// mustListing returns the stored listing id (a pointer into state).
func mustListing(id uint64) *Listing {
	v := listings.Get(listingKey(id))
	if v == nil {
		panic("town: no such listing")
	}
	return v.(*Listing)
}

// listingKey is id in decimal, zero-padded to 12 digits, so the tree orders
// keys by ID.
func listingKey(id uint64) string {
	var b [listingIDWidth]byte
	for i := listingIDWidth - 1; i >= 0; i-- {
		b[i] = byte('0' + id%10)
		id /= 10
	}
	return string(b[:])
}
