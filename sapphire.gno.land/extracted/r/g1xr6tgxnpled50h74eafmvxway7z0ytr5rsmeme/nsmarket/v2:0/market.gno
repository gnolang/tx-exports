package nsmarket

import (
	"strings"
	"time"

	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/grc721"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nslogic/v7"
)

// List puts a name up for sale at a price in ugnot.
//
// It does NOT take the name. The seller keeps it, keeps using it, and
// keeps the right to change their mind — revoking the approval kills the
// listing without needing this realm's cooperation at all.
//
// The approval is required BEFORE listing rather than checked only at
// sale time, so a listing that could never complete cannot exist. A
// buyer finding out at the checkout that the seller never approved
// anything is the worst moment to find out.
func List(cur realm, tid string, price int64) {
	assertNoSend()
	seller := cur.Previous().Address()
	label, domainLabel := splitTokenID(tid)
	if label == "" || domainLabel == "" {
		panic("nsmarket: a token id looks like label*domain")
	}
	if strings.HasPrefix(tid, "*") {
		panic("nsmarket: domains are project-owned and not for sale")
	}
	if price < minPrice || price > maxPrice {
		panic("nsmarket: price out of range")
	}
	if !nsdata.NameExists(label, domainLabel) {
		panic("nsmarket: no such name")
	}
	if nsdata.GetNameOwner(label, domainLabel) != seller {
		panic("nsmarket: only the owner may list a name")
	}
	// An expired name cannot be transferred, so it cannot be sold. Saying
	// so here rather than letting somebody list it and take an offer.
	if !nsdata.IsNameValid(label, domainLabel) {
		panic("nsmarket: this name has expired — renew it before selling it")
	}
	if !nsdata.IsNameNFT(label, domainLabel) {
		panic("nsmarket: this name has no token yet; mint one before selling it")
	}
	if !approvedTo(cur.Address(), seller, tid) {
		panic("nsmarket: approve the marketplace for this name first, so a sale can complete in one transaction")
	}

	listings.Set(tid, &Listing{seller: seller, price: price, listed: time.Now().Unix()})
	chain.Emit("Listed", "tid", tid, "price", ufmt.Sprintf("%d", price), "seller", seller.String())
}

// Unlist withdraws a listing. The seller, or the admin for a name that
// should not be on sale at all — the same manual lever the takedown
// process already relies on elsewhere.
func Unlist(cur realm, tid string) {
	assertNoSend()
	caller := cur.Previous().Address()
	l := get(tid)
	if l == nil {
		panic("nsmarket: not listed")
	}
	if caller != l.seller && caller != nsdata.GetAdmin() {
		panic("nsmarket: only the seller may withdraw a listing")
	}
	listings.Remove(tid)
	chain.Emit("Unlisted", "tid", tid)
}

// Buy completes a sale in the buyer's own transaction.
//
// Order matters here. Everything that can refuse the sale is checked
// before a single coin moves, and the name moves before the money does,
// so there is no arrangement of failures that leaves the seller paid and
// the buyer empty-handed. A panic anywhere reverts all of it.
func Buy(cur realm, tid string) {
	if !cur.Previous().IsUserCall() {
		panic("nsmarket: only direct wallet calls may buy")
	}
	buyer := cur.Previous().Address()
	l := get(tid)
	if l == nil {
		panic("nsmarket: not listed")
	}
	label, domainLabel := splitTokenID(tid)

	// The world can have moved since the listing was written. Each of
	// these is a real thing that happens, not a defensive flourish: the
	// seller can transfer the name elsewhere, let it lapse, or revoke
	// the approval, and none of those tell this realm about it.
	if nsdata.GetNameOwner(label, domainLabel) != l.seller {
		listings.Remove(tid)
		panic("nsmarket: this name has changed hands since it was listed — the listing is gone")
	}
	if !nsdata.IsNameValid(label, domainLabel) {
		panic("nsmarket: this name has expired; it cannot be transferred")
	}
	if !approvedTo(cur.Address(), l.seller, tid) {
		listings.Remove(tid)
		panic("nsmarket: the seller has withdrawn permission — the listing is gone")
	}
	if buyer == l.seller {
		panic("nsmarket: you already own this")
	}

	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != ugnot {
			panic("nsmarket: only ugnot is accepted, got: " + c.Denom)
		}
	}
	paid := sent.AmountOf(ugnot)
	if paid < l.price {
		panic(ufmt.Sprintf("nsmarket: %d ugnot short of the asking price", l.price-paid))
	}

	// The name first. If this fails nothing has been paid out yet, and
	// the revert takes the buyer's coins back with it.
	nslogic.TransferFrom(cross(cur), l.seller, buyer, tid)

	fee, toSeller := FeeFor(l.price)
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	self := cur.Address()
	if toSeller > 0 {
		b.SendCoins(self, l.seller, chain.Coins{chain.NewCoin(ugnot, toSeller)})
	}
	if fee > 0 {
		b.SendCoins(self, nsdata.GetTreasury(), chain.Coins{chain.NewCoin(ugnot, fee)})
	}
	if excess := paid - l.price; excess > 0 {
		b.SendCoins(self, buyer, chain.Coins{chain.NewCoin(ugnot, excess)})
	}

	listings.Remove(tid)
	sold++
	chain.Emit("Sold", "tid", tid, "price", ufmt.Sprintf("%d", l.price),
		"seller", l.seller.String(), "buyer", buyer.String(),
		"fee", ufmt.Sprintf("%d", fee))
}

// -- helpers --

func get(tid string) *Listing {
	v := listings.Get(tid)
	if v == nil {
		return nil
	}
	return v.(*Listing)
}

// Whether this realm may move that token on the seller's behalf. Either
// form of GRC-721 permission counts: approved for the one token, or an
// operator for everything the seller holds.
//
// `self` is threaded in from the caller rather than looked up, because a
// realm can only learn its own address from its own `cur`.
func approvedTo(self, seller address, tid string) bool {
	if nsdata.GetApproved(grc721.TokenID(tid)) == self {
		return true
	}
	return nsdata.IsApprovedForAll(seller, self)
}

func splitTokenID(tid string) (label, domainLabel string) {
	at := strings.Index(tid, "*")
	if at < 1 || at == len(tid)-1 {
		return "", ""
	}
	return tid[:at], tid[at+1:]
}

// This realm takes no payment on anything except Buy.
func assertNoSend() {
	if !unsafe.OriginSend().IsZero() {
		panic("nsmarket: this function takes no payment; do not attach coins")
	}
}
