package nsmarket

import (
	"strings"
	"time"

	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsdata/v1"
	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsnft/v1"
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
// assertNotFrozen — the freeze has to bind here too.
//
// nsnft refuses to move a frozen name — the freeze is a hold on the token
// — which already stops a sale from completing. This check exists so it stops EARLIER: a frozen name
// should not sit on the marketplace advertising itself, and a buyer
// should not discover the problem by having their transaction panic
// after they have chosen to pay.
//
// The bit comes from GetNameInfo, which has always returned it.
func assertNotFrozen(label, domainLabel string) {
	_, _, _, _, frozen, _ := nsdata.GetNameInfo(label, domainLabel)
	if frozen {
		panic("nsmarket: this name is frozen and cannot be listed or sold")
	}
}

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
	assertNotFrozen(label, domainLabel)
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
	if !nsdata.IsNamePaid(label, domainLabel) {
		panic("nsmarket: a free-tier name cannot be sold — upgrade it first")
	}
	// A hold for any other reason — frozen is the one today — stops the
	// listing here rather than at checkout. nsnft would refuse the
	// transfer anyway; a buyer should not find out by paying.
	if nsnft.IsLocked(tid) {
		panic("nsmarket: this name is held by the registry and cannot be sold")
	}
	if !approvedTo(cur.Address(), seller, tid) {
		panic("nsmarket: approve the marketplace for this name first, so a sale can complete in one transaction")
	}

	_, registered, _, _, _, _ := nsdata.GetNameInfo(label, domainLabel)
	listings.Set(tid, &Listing{seller: seller, price: price,
		listed: time.Now().Unix(), registered: registered, epoch: nsnft.Epoch(tid)})
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
	assertNotFrozen(label, domainLabel)

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
	/* SAME NAME, SAME REGISTRATION. Owner and validity both match after
	   a lapse-and-self-re-registration, because it is genuinely the same
	   person holding the same label — but it is not the same asset the
	   listing was written against, and the seller has already paid to
	   get it back once. Listings written before this field existed carry
	   zero, which is treated as unpinned rather than as a mismatch, so
	   nothing already on the market is stranded by the upgrade. */
	if l.registered != 0 {
		_, registered, _, _, _, _ := nsdata.GetNameInfo(label, domainLabel)
		if registered != l.registered {
			listings.Remove(tid)
			panic("nsmarket: this name lapsed and was registered again since it was listed — the listing is gone")
		}
	}
	// Same ownership epoch — see Listing.epoch for the buy-back case this
	// is the only check that catches.
	if l.epoch != 0 && l.epoch != nsnft.Epoch(tid) {
		listings.Remove(tid)
		panic("nsmarket: this name has changed hands since it was listed — the listing is gone")
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
	//
	// ON nsnft, AS THE APPROVED OPERATOR — exactly the call any external
	// marketplace makes. This realm has no privileged transfer path, which
	// is the point: the sale is only possible because the seller approved
	// this realm on the ledger, and revoking that approval there kills
	// the listing without our cooperation.
	nsnft.TransferFrom(cross(cur), l.seller, buyer, tid)

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
	/* THE OPERATOR CHECK GOES FIRST, and that ordering is the whole fix.
	   nsdata.GetApproved PANICS for a token with no per-token approval
	   rather than returning the zero address, so putting it first made
	   the line below unreachable: a seller who granted blanket
	   permission with SetApprovalForAll and called List got a raw vault
	   panic, and the comment above claiming either form counts was
	   false. Asking the total question first makes it true. */
	if nsdata.IsApprovedForAll(seller, self) {
		return true
	}
	return nsdata.GetApproved(tid) == self
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
