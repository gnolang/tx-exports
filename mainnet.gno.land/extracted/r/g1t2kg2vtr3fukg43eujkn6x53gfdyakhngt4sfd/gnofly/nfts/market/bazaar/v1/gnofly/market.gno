package gnofly

import (
	"chain"
	"chain/banker"
	"strconv"

	// Only for OriginSend, in Buy. Caller identity always comes from cur,
	// never from this package.
	"chain/runtime/unsafe"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/grc721/v0"

	bazaar "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/bazaarv5"

	"gno.land/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/nfts/planes"
)

const (
	payDenom = "ugnot"

	// minPrice keeps the royalty above zero after rounding: 5% of 1 GNOT.
	minPrice = int64(1_000_000)
	// maxPrice keeps price * royalty bps far below an int64.
	maxPrice = int64(1_000_000_000_000)

	supply = 777 // plane ids run from 1 to 777
)

// listing is one plane for sale. The plane itself is held by this realm
// (escrow) until it is bought or the listing is cancelled.
type listing struct {
	seller address
	price  int64 // ugnot
}

var (
	// listings by plane id, as a three-digit key ("042") so that iteration
	// runs in id order.
	listings bptree.BPTree
	// paused stops new listings and price changes, for a move to a newer
	// version of the market. Cancel and Buy keep working: nothing listed here
	// can be stuck.
	paused bool
	// self is this realm's address, recorded at init: what sellers approve
	// on the planes realm.
	self address
)

func init(cur realm) {
	self = cur.Address()
}

// List puts plane id up for sale at priceUgnot. The caller must own it and
// have approved this realm on the planes realm (Approve for this plane, or
// SetApprovalForAll): the plane moves here, in escrow, until it is bought or
// the listing is cancelled.
func List(cur realm, id int, priceUgnot int64) {
	seller := userOf(0, cur)
	if paused {
		panic(errPaused)
	}
	checkPrice(priceUgnot)
	if listings.Has(key(id)) {
		panic(errListed)
	}
	if owner := ownerOf(id); owner != seller {
		panic(errNotOwner)
	}
	if !planes.IsApprovedForAll(seller, self) && planes.GetApproved(int64(id)) != self {
		panic(errNotApproved)
	}
	listings.Set(key(id), &listing{seller: seller, price: priceUgnot})
	planes.TransferFrom(cross(cur), seller, self, int64(id))
	noteMinted(0, cur)
	chain.Emit("List", "id", strconv.Itoa(id), "seller", seller.String(), "price", strconv.FormatInt(priceUgnot, 10))
}

// UpdatePrice changes the price of a plane the caller listed.
func UpdatePrice(cur realm, id int, priceUgnot int64) {
	seller := userOf(0, cur)
	if paused {
		panic(errPaused)
	}
	checkPrice(priceUgnot)
	l := mustListing(id)
	if l.seller != seller {
		panic(errNotSeller)
	}
	l.price = priceUgnot
	chain.Emit("UpdatePrice", "id", strconv.Itoa(id), "seller", seller.String(), "price", strconv.FormatInt(priceUgnot, 10))
}

// Cancel takes a listing down and gives the plane back to its seller. It
// works while the market is paused.
func Cancel(cur realm, id int) {
	seller := userOf(0, cur)
	l := mustListing(id)
	if l.seller != seller {
		panic(errNotSeller)
	}
	listings.Remove(key(id))
	planes.TransferFrom(cross(cur), cur.Address(), seller, int64(id))
	chain.Emit("Cancel", "id", strconv.Itoa(id), "seller", seller.String())
}

// Buy buys a listed plane: send exactly its price in ugnot. Out of the price:
// Bazaar's fee (bazaarFee, to its sinks), the planes realm's royalty
// (RoyaltyInfo: 5% to the gnofly treasury), and the rest to the seller; the
// plane goes to the buyer. It works while the market is paused.
func Buy(cur realm, id int) {
	// A direct user call: only then has the -send envelope landed at this
	// realm's address, which the OriginSend banker below pays out of.
	buyer := userOf(0, cur)
	l := mustListing(id)
	if l.seller == buyer {
		panic(errOwnListing)
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != payDenom || sent[0].Amount != l.price {
		panic("gnofly market: wrong payment, send exactly " + strconv.FormatInt(l.price, 10) + payDenom)
	}
	// The listing goes before any coin or plane moves.
	listings.Remove(key(id))

	bank := banker.NewBanker(banker.BankerTypeOriginSend, cur)
	pay := func(to address, amount int64) int64 {
		if amount <= 0 || !to.IsValid() {
			return 0
		}
		bank.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin(payDenom, amount)))
		return amount
	}
	genesis, protocol := bazaarFee(l.price, l.seller, buyer)
	fee := pay(bazaar.GenesisSink(), genesis) + pay(bazaar.ProtocolSink(), protocol)
	receiver, royalty := planes.RoyaltyInfo(int64(id), l.price)
	if royalty < 0 || royalty > l.price-fee {
		royalty = 0
	}
	royalty = pay(receiver, royalty)
	pay(l.seller, l.price-fee-royalty)

	planes.TransferFrom(cross(cur), cur.Address(), buyer, int64(id))
	noteMinted(0, cur)
	chain.Emit("Buy", "id", strconv.Itoa(id), "seller", l.seller.String(), "buyer", buyer.String(),
		"price", itoa64(l.price), "royalty", itoa64(royalty), "fee", itoa64(fee))
}

// Transfer gives a plane the caller owns, not listed, to another address,
// through this realm: the call Bazaar's site makes. It needs the same
// approval as List. A plane can always be moved on the planes realm itself.
func Transfer(cur realm, to address, id int) {
	from := userOf(0, cur)
	if !to.IsValid() {
		panic(errBadRecipient)
	}
	if listings.Has(key(id)) {
		panic(errListed)
	}
	if owner := ownerOf(id); owner != from {
		panic(errNotOwner)
	}
	planes.TransferFrom(cross(cur), from, to, int64(id))
	chain.Emit("Transfer", "id", strconv.Itoa(id), "from", from.String(), "to", to.String())
}

// SetPaused stops (or resumes) new listings and price changes. Admin of the
// game realm only. Cancel and Buy keep working, so a move to a newer market
// never strands a plane: sellers cancel here and list there.
func SetPaused(cur realm, p bool) {
	assertAdmin(0, cur)
	paused = p
	chain.Emit("Paused", "paused", strconv.FormatBool(p))
}

// ReturnStray gives back a plane this realm holds outside any listing: one
// someone sent here by mistake. Admin of the game realm only; to is who it
// came from, as the chain's transfer events show.
func ReturnStray(cur realm, id int, to address) {
	assertAdmin(0, cur)
	if !to.IsValid() {
		panic(errBadRecipient)
	}
	if listings.Has(key(id)) || ownerOf(id) != cur.Address() {
		panic(errNotStray)
	}
	planes.TransferFrom(cross(cur), cur.Address(), to, int64(id))
	chain.Emit("ReturnStray", "id", strconv.Itoa(id), "to", to.String())
}

// Paused reports whether new listings are stopped.
func Paused() bool { return paused }

// checkPrice panics unless p is a price this market takes.
func checkPrice(p int64) {
	if p < minPrice || p > maxPrice {
		panic(errBadPrice)
	}
}

// mustListing returns the listing of plane id, or panics.
func mustListing(id int) *listing {
	v := listings.Get(key(id))
	if v == nil {
		panic(errNotListed)
	}
	return v.(*listing)
}

// getListing returns the listing of plane id, or nil.
func getListing(id int) *listing {
	if v := listings.Get(key(id)); v != nil {
		return v.(*listing)
	}
	return nil
}

// ownerOf returns the owner of plane id on the planes realm, or panics for
// an id that is not a minted plane.
func ownerOf(id int) address {
	if id < 1 || id > supply {
		panic(errUnknownPlane)
	}
	owner, err := planes.OwnerOf(tid(id))
	if err != nil {
		panic(errUnknownPlane)
	}
	return owner
}

// key is the listings key of plane id: three digits, "042".
func key(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 3 {
		s = "0" + s
	}
	return s
}

func tid(id int) grc721.TokenID { return grc721.TokenID(strconv.Itoa(id)) }
