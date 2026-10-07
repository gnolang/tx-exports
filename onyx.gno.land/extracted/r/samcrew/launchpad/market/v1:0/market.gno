// Package market trades Launchpad NFTs: fixed-price listings and funded
// offers. A sale pays the seller, the treasury and the collection's royalty
// receivers inside the same transaction. The realm holds only the escrow of
// open offers, which their buyers can always take back, and has no admin. It
// keeps open orders only: a closed one is deleted, so its storage deposit is
// released, and its history is the event log.
package market

import (
	"chain"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/samcrew/launchpad/currency/v1"
	"gno.land/r/samcrew/launchpad/nft/v1"
)

const (
	marketPath = "gno.land/r/samcrew/launchpad/market/v1"

	// Why an order closed, as its closing event says.
	StatusFilled    = "filled"
	StatusCancelled = "cancelled"
	StatusReplaced  = "replaced"
	StatusExpired   = "expired"

	// Hard limits, fixed for the life of this realm.
	maxSecondaryFeeBPS = 200 // 2% of a sale price
	maxLifetime        = 90 * 24 * 60 * 60
	// How long after its expiry an order is still its owner's alone to close.
	// The chain returns the storage deposit of the bytes a call frees to that
	// call's sender (while ugnot is not a restricted denomination): the grace
	// keeps a stranger from taking a closed order's deposit at the very second
	// it expires, and leaves abandoned orders to whoever cleans them up.
	graceToClose = 7 * 24 * 60 * 60
	maxOrders    = 9_999_999_999
)

// Listing offers one token at a fixed price. The seller keeps the token and
// approves this realm; nothing is held here. A listing exists while it is
// open and no longer, and can be bought only within the token's custody epoch
// it was made in.
type Listing struct {
	ID         string // "L<n>"
	Collection string
	Number     int64
	Seller     address
	Price      int64
	Currency   string
	CreatedAt  int64
	ExpiresAt  int64
	FeeBPS     int64  // protocol fee, pinned when the seller signed
	key        string // its key in listings
	epoch      int64  // the token's custody epoch when it was listed
}

var (
	lastListing seqid.ID
	listings    avl.Tree // listing key -> *Listing, in creation order
	listed      avl.Tree // "<collection>/<token number key>" -> *Listing
	bySeller    avl.Tree // "<seller>/<listing key>" -> *Listing
)

func directCaller(cur realm) address {
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic("launchpad/market: direct user call required")
	}
	return cur.Previous().Address()
}

// orderKey reads an order ID, its prefix ('L' listing, 'O' offer) then its
// number, as its tree key.
func orderKey(prefix byte, id string) (string, bool) {
	if len(id) < 2 || len(id) > 11 || id[0] != prefix || id[1] == '0' {
		return "", false
	}
	n, err := strconv.ParseUint(id[1:], 10, 64)
	if err != nil {
		return "", false
	}
	return seqid.ID(n).String(), true
}

func nextOrder(last *seqid.ID, prefix string) (string, string) {
	if uint64(*last) >= maxOrders {
		panic("launchpad/market: order ID exhausted")
	}
	n := last.Next()
	return prefix + strconv.FormatUint(uint64(n), 10), n.String()
}

// findListing returns an open listing, or nil: a closed one is gone.
func findListing(id string) *Listing {
	if key, ok := orderKey('L', id); ok {
		if l := listings.Get(key); l != nil {
			return l.(*Listing)
		}
	}
	return nil
}

func mustListing(id string) *Listing {
	if l := findListing(id); l != nil {
		return l
	}
	panic("launchpad/market: unknown listing")
}

// tokenKey sorts a collection's tokens in number order.
func tokenKey(collection string, number int64) string {
	return collection + "/" + seqid.ID(number).String()
}

// listingOf returns the open listing of a token, or nil.
func listingOf(collection string, number int64) *Listing {
	if l := listed.Get(tokenKey(collection, number)); l != nil {
		return l.(*Listing)
	}
	return nil
}

// sellable reports whether seller owns the active token and has approved this
// realm for that token. Only a single-token approval counts, as an approval
// for all would outlive the token's moves.
func sellable(collection string, number int64, seller address) bool {
	return nft.StatusOf(collection, number) == nft.StatusActive &&
		nft.OwnerOf(collection, number) == seller &&
		nft.GetApproved(collection, number) == chain.PackageAddress(marketPath)
}

// pinned checks what every new order needs (a collection that can be sold, a
// price, a lifetime of at most 90 days) and returns the protocol fee to pin
// on it: the current one, which must not exceed what its owner accepts nor
// this realm's cap.
func pinned(collection string, price, expiresAt int64, currencyKey string, maxFeeBPS int64) int64 {
	fee := policy(currencyKey).feeBPS
	if fee > maxFeeBPS || fee > maxSecondaryFeeBPS {
		panic("launchpad/market: protocol fee above the accepted maximum")
	}
	now := time.Now().Unix()
	if nft.GetInfo(collection).Mode == nft.ModeSoulbound || price <= 0 ||
		expiresAt <= now || expiresAt > now+maxLifetime {
		panic("launchpad/market: invalid order")
	}
	return fee
}

// List offers the caller's token for sale and returns the listing ID. The
// caller must first approve this realm in the NFT ledger, and names the
// highest protocol fee it accepts; the fee in force is pinned on the listing.
// A new listing replaces the token's previous one.
func List(cur realm, collection string, number, price, expiresAt int64,
	currencyKey string, maxFeeBPS int64) string {
	seller := directCaller(cur)
	currency.AssertNoCoins(0, cur)
	fee := pinned(collection, price, expiresAt, currencyKey, maxFeeBPS)
	if !sellable(collection, number, seller) {
		panic("launchpad/market: not the owner, or the market is not approved")
	}
	if old := listingOf(collection, number); old != nil {
		closeListing(old, StatusReplaced)
	}
	id, treeKey := nextOrder(&lastListing, "L")
	l := &Listing{ID: id, Collection: collection, Number: number, Seller: seller,
		Price: price, Currency: currencyKey, CreatedAt: time.Now().Unix(),
		ExpiresAt: expiresAt, FeeBPS: fee, key: treeKey,
		epoch: nft.Epoch(collection, number)}
	listings.Set(treeKey, l)
	listed.Set(tokenKey(collection, number), l)
	bySeller.Set(seller.String()+"/"+treeKey, l)
	chain.Emit("Listed", "listing", id, "collection", collection,
		"number", strconv.FormatInt(number, 10), "seller", seller.String(),
		"currency", currencyKey, "price", strconv.FormatInt(price, 10),
		"fee_bps", strconv.FormatInt(fee, 10),
		"expires_at", strconv.FormatInt(expiresAt, 10))
	return id
}

// closeListing deletes a listing and says why in its closing event.
func closeListing(l *Listing, status string) {
	listings.Remove(l.key)
	listed.Remove(tokenKey(l.Collection, l.Number))
	bySeller.Remove(l.Seller.String() + "/" + l.key)
	chain.Emit("ListingClosed", "listing", l.ID, "status", status)
}

// live reports whether a listing can be bought right now. A move or an
// approval change starts a new custody epoch, so a listing never comes back to
// life when a token that left the seller returns or the market is approved
// again: the seller lists anew.
func live(l *Listing) bool {
	return time.Now().Unix() < l.ExpiresAt && sellable(l.Collection, l.Number, l.Seller) &&
		nft.Epoch(l.Collection, l.Number) == l.epoch
}

// Cancel withdraws a listing. The seller can always do it, paused market or
// not. Anyone can clear a listing whose seller no longer owns the token, or
// one that expired more than graceToClose ago; the chain returns the storage
// deposit of what a call frees to its caller, so clearing pays whoever does
// it.
func Cancel(cur realm, id string) {
	who := directCaller(cur)
	currency.AssertNoCoins(0, cur)
	l := mustListing(id)
	stale := time.Now().Unix() >= l.ExpiresAt+graceToClose ||
		nft.StatusOf(l.Collection, l.Number) != nft.StatusActive ||
		nft.OwnerOf(l.Collection, l.Number) != l.Seller
	switch {
	case who == l.Seller:
		closeListing(l, StatusCancelled)
	case stale:
		closeListing(l, StatusExpired)
	default:
		panic("launchpad/market: seller only")
	}
}

// Buy pays a listing's exact price and moves the token to the caller.
// currencyKey and price are the terms the buyer read: a listing on other
// terms, such as an ID the buyer never saw, takes nothing.
func Buy(cur realm, id, currencyKey string, price int64) {
	buyer := directCaller(cur)
	l := mustListing(id)
	if l.Currency != currencyKey || l.Price != price {
		panic("launchpad/market: order terms differ from those signed")
	}
	p := policy(l.Currency)
	if buyer == l.Seller || !live(l) {
		panic("launchpad/market: listing unavailable")
	}
	before := take(cur, l.Currency, l.Price)
	closeListing(l, StatusFilled)
	nft.TransferFrom(cross(cur), l.Collection, l.Seller, buyer, l.Number)
	settle(cur, l.Currency, l.Collection, l.Price, l.FeeBPS, l.Seller, p.treasury)
	settled(cur, l.Currency, before)
	chain.Emit("Sold", "listing", id, "collection", l.Collection,
		"number", strconv.FormatInt(l.Number, 10), "buyer", buyer.String(),
		"seller", l.Seller.String(), "currency", l.Currency,
		"price", strconv.FormatInt(l.Price, 10))
}

// GetListing returns an open listing; a closed or unknown ID aborts.
func GetListing(id string) Listing { return *mustListing(id) }

func Render(path string) string {
	return "# Launchpad NFT market\n\n" + strconv.Itoa(listings.Size()) +
		" open listings, " + strconv.Itoa(offers.Size()) + " open offers.\n"
}
