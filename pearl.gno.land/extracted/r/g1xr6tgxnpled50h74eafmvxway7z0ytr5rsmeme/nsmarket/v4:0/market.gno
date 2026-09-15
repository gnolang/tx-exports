package nsmarket

import (
	"strings"
	"time"

	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/grc721"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v1"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nslogic/v4"
)

// List puts a name up for sale at a price in ugnot.
//
// It does NOT take the name. The seller keeps it, keeps using it, and
// keeps the right to change their mind.
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
	// A frozen name should not sit on the marketplace advertising itself.
	// nslogic.TransferFrom refuses it anyway; a buyer should not find out
	// by paying.
	_, registered, _, _, frozen, _ := nsdata.GetNameInfo(label, domainLabel)
	if frozen {
		panic("nsmarket: this name is frozen and cannot be listed or sold")
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
	// Panics with the vault's own error when there is no per-token
	// approval at all — a refusal either way.
	if !approvedTo(cur.Address(), tid) {
		panic("nsmarket: approve the marketplace for this name first (Approve, for this one name — a blanket operator approval does not count here), so a sale can complete in one transaction")
	}

	listings.Set(tid, &Listing{seller: seller, price: price,
		listed: time.Now().Unix(), registered: registered})
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
name is transferred elsewhere, lapses, is frozen, or the seller points the
approval somewhere else. Buy refuses such a listing — but a refusal is a
panic, and a panic reverts everything, including the attempt to delete the
listing on the way out. v3 did exactly that: it removed the listing,
panicked with "the listing is gone", and the revert put the listing back.
Found on the Pearl sandbox, 2026-09-10.

ONE CASE PRUNE CANNOT CLEAR: a name that left the seller and came back.
Every transfer wipes the per-token approval, and nsdata/v1's GetApproved
panics when there is none — a panic nothing here can catch. That listing
still cannot SELL (Buy panics the same way), so it is harmless; the seller
or the admin removes it with Unlist.

The pruner gains only the listing's storage deposit, which the chain
refunds to whoever frees storage. staleReason must name a reason or
Prune refuses, so the only thing it can remove is a listing already dead.
*/
func Prune(cur realm, tid string) {
	assertNoSend()
	l := get(tid)
	if l == nil {
		panic("nsmarket: not listed")
	}
	why := staleReason(cur.Address(), tid, l, true)
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
	if why := staleReason(cur.Address(), tid, l, true); why != "" {
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

/*
staleReason says why a listing can no longer complete, or "" when it can.

ONE ANSWER FOR THREE CALLERS: Buy refuses on it, Prune clears on it, the
reads report live=false on it.

withApproval is false for the READS, and that is forced, not chosen.
nsdata/v1's GetApproved panics for a token with no per-token approval, and
recover() does not catch a panic raised inside another realm's function
(tested 2026-09-14, non-crossing call included). Every transfer wipes the
approval, so a seller who lists, sends the name to a second wallet and
back would make one row panic — and ListForSale, the whole marketplace
page, with it, for everyone. So the reads stay blind to a withdrawn
approval; the site checks each listing's approval itself (market.js), where
a failed query is just an answer. Buy and Prune may panic: for them a panic
is a refusal.
*/
func staleReason(self address, tid string, l *Listing, withApproval bool) string {
	label, domainLabel := splitTokenID(tid)
	if !nsdata.NameExists(label, domainLabel) {
		return "this name no longer exists"
	}
	_, registered, _, _, frozen, _ := nsdata.GetNameInfo(label, domainLabel)
	if frozen {
		return "this name is frozen"
	}
	if nsdata.GetNameOwner(label, domainLabel) != l.seller {
		return "this name has changed hands since it was listed"
	}
	if !nsdata.IsNameValid(label, domainLabel) {
		return "this name has expired"
	}
	if l.registered != 0 && registered != l.registered {
		return "this name lapsed and was registered again since it was listed"
	}
	if withApproval && !approvedTo(self, tid) {
		return "the seller has withdrawn permission"
	}
	return ""
}

/*
Whether this realm holds the PER-TOKEN approval for the name. Panics (the
vault's error) when the token has no per-token approval at all.

ONLY THE PER-TOKEN APPROVAL COUNTS, unlike v3, which also accepted an
operator grant (SetApprovalForAll). This vault has no ownership epoch, and
an operator grant survives transfers — so under one, a name listed, sold
elsewhere and bought back had its old listing complete again at the old
price, and a listing "cancelled" by withdrawing the approval came back the
day the seller granted an operator approval for anything else. A per-token
approval is wiped by every transfer, so it cannot outlive the ownership it
was given under. The site only ever asks for per-token approval.
*/
func approvedTo(self address, tid string) bool {
	return nsdata.GetApproved(grc721.TokenID(tid)) == self
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
