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
// keeps the right to change their mind — revoking the approval stops the
// listing from completing without needing this realm's cooperation.
// (It does not DELETE the listing: this realm is not told. Unlist, or
// anyone's Prune, clears it. See staleReason.)
//
// The approval is required BEFORE listing rather than checked only at
// sale time, so a listing that could never complete cannot exist. A
// buyer finding out at the checkout that the seller never approved
// anything is the worst moment to find out.
func List(cur realm, tid string, price int64) {
	assertNoSend()
	seller := cur.Previous().Address()
	marketAddr = cur.Address()
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
	// A frozen name should not sit on the marketplace advertising itself.
	// nsnft would refuse the transfer anyway; a buyer should not find out
	// by paying.
	if !nsdata.NameExists(label, domainLabel) {
		panic("nsmarket: no such name")
	}
	_, registered, _, _, frozen, _ := nsdata.GetNameInfo(label, domainLabel)
	if frozen {
		panic("nsmarket: this name is frozen and cannot be listed or sold")
	}
	if nsdata.GetNameOwner(label, domainLabel) != seller {
		panic("nsmarket: only the owner may list a name")
	}
	// An expired name must not be sold here. Saying so at listing time
	// rather than letting somebody list it and take an offer.
	if !nsdata.IsNameValid(label, domainLabel) {
		panic("nsmarket: this name has expired — renew it before selling it")
	}
	if !nsdata.IsNamePaid(label, domainLabel) {
		panic("nsmarket: a free-tier name cannot be sold — upgrade it first")
	}
	// A hold for any other reason — frozen is the one today — stops the
	// listing here rather than at checkout.
	if nsnft.IsLocked(tid) {
		panic("nsmarket: this name is held by the registry and cannot be sold")
	}
	if !approvedTo(cur.Address(), seller, tid) {
		panic("nsmarket: approve the marketplace for this name first, so a sale can complete in one transaction")
	}

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

/*
Prune clears a listing that can no longer complete. Anyone may call it.

WHY ANYONE. A listing goes stale without this realm hearing about it: the
name is transferred elsewhere, lapses, is frozen, or the seller revokes
the approval. Buy refuses such a listing — but a refusal is a panic, and a
panic reverts everything, including any attempt to delete the listing on
the way out. Found on Pearl, 2026-09-10: three refused buys, three
listings still stored, each message saying "the listing is gone".

A stale listing is not harmless while it sits there. Revoking the approval
is how a seller would naturally "cancel"; if that seller later grants the
marketplace an operator approval to list something else, the old listing
completes again, at the old price. Clearing it is the fix, and nobody
should have to wait for the seller to think of it.

The caller gains nothing but the storage deposit the listing held, which
the chain refunds to whoever frees storage. That is the right incentive:
the only thing Prune can do is remove a listing that is already dead —
staleReason must name a reason, or it refuses.
*/
func Prune(cur realm, tid string) {
	assertNoSend()
	l := get(tid)
	if l == nil {
		panic("nsmarket: not listed")
	}
	why := staleReason(cur.Address(), tid, l)
	if why == "" {
		panic("nsmarket: this listing can still complete — only the seller may withdraw it")
	}
	listings.Remove(tid)
	chain.Emit("Pruned", "tid", tid, "reason", why)
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
	// The world can have moved since the listing was written. The refusal
	// cannot also delete the listing — see Prune for why.
	if why := staleReason(cur.Address(), tid, l); why != "" {
		panic("nsmarket: " + why + " — this listing can no longer complete (anyone may clear it with Prune)")
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
	// this realm on the ledger.
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

/*
staleReason says why a listing can no longer complete, or "" when it can.

ONE ANSWER FOR THREE CALLERS. Buy refuses on it, Prune clears on it, and
the reads report live=false on it. They used to be three separate lists of
checks, and the reads' list had no approval check: a listing whose seller
had revoked permission showed as live, with an enabled Buy button, and
failed at the checkout.

Each of these is a real thing that happens, not a defensive flourish:
  - changed hands: the seller transferred the name elsewhere
  - lapsed and re-registered: owner and validity match again, but it is
    not the asset the listing was written against (Listing.registered)
  - sold and bought back: same owner, same registration, but a different
    ownership epoch — an operator grant survives transfers (Listing.epoch)
  - withdrawn permission: the seller revoked the approval
*/
func staleReason(self address, tid string, l *Listing) string {
	label, domainLabel := splitTokenID(tid)
	if !nsdata.NameExists(label, domainLabel) {
		return "this name no longer exists"
	}
	_, registered, _, _, frozen, _ := nsdata.GetNameInfo(label, domainLabel)
	if frozen || nsnft.IsLocked(tid) {
		return "this name is frozen"
	}
	if nsdata.GetNameOwner(label, domainLabel) != l.seller {
		return "this name has changed hands since it was listed"
	}
	if !nsdata.IsNameValid(label, domainLabel) {
		return "this name has expired"
	}
	// Zero means written before the field existed: unpinned, not mismatched.
	if l.registered != 0 && registered != l.registered {
		return "this name lapsed and was registered again since it was listed"
	}
	if l.epoch != 0 && l.epoch != nsnft.Epoch(tid) {
		return "this name has changed hands since it was listed"
	}
	if self == "" || !approvedTo(self, l.seller, tid) {
		return "the seller has withdrawn permission"
	}
	return ""
}

// Whether this realm may move that token on the seller's behalf. Either
// form of GRC-721 permission counts: approved for the one token, or an
// operator for everything the seller holds.
//
// `self` is threaded in from the caller rather than looked up, because a
// realm can only learn its own address from its own `cur`.
func approvedTo(self, seller address, tid string) bool {
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
