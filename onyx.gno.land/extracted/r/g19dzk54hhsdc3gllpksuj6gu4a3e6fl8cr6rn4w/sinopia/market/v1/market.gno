// Package market is the platform's immutable fixed-price market
// (design §2.5.4). It never holds a token: the seller approves this
// realm in core, the token stays in the seller's wallet, and Buy moves it
// through core's official grc721 RealmTeller in the same transaction that
// pays everyone. It never holds coins either (I-3).
//
// Stale listings (RA H-2) cannot be bought: a listing pins the token's
// move counter at listing time, and Buy requires owner == seller and the
// counter unchanged (I-8). A listing that went stale never blocks the new
// owner: List overwrites it and anyone may CancelStale it.
//
// Pause ("trade" in core) stops List and Buy only. Cancel, CancelStale and
// UpdatePrice are never paused (I-2).
package market

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"

	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/sinopia/safe/v1"
	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/sinopia/types/v1"
	"gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/sinopia/core"
)

const (
	MaxPageSize = 50
	idWidth     = 12
	priceWidth  = 16 // types.MaxUnitPrice has 16 digits
)

type listing struct {
	id       int64
	cid, tid string
	seller   address
	price    int64
	moves    int64 // core.TokenMoves at listing time
	height   int64
}

var (
	listings     avl.Tree // padded id -> *listing
	byToken      avl.Tree // cid:tid -> id
	byCollection avl.Tree // cid:paddedPrice:paddedID -> id (floor = first key)
	bySeller     avl.Tree // seller:paddedID -> id
	nextID       int64
	selfPath     string // captured in init for read paths without a cur
)

func init(cur realm) {
	selfPath = cur.PkgPath()
}

// List offers a token of a Final collection at price (ugnot). The caller
// must own it and have approved this realm (Approve or SetApprovalForAll in
// core). A stale listing of the same token is replaced.
func List(cur realm, cid, tid string, price int64) string {
	assertNoDeposit(cur)
	assertTradeOpen()
	assertPrice(price)
	seller := cur.Previous().Address()
	if core.Info(cid).State != types.StateFinal {
		panic("tokens of this collection are locked until it is final")
	}
	owner, err := core.OwnerOf(cid, tid)
	if err != nil {
		panic(err)
	}
	if owner != seller {
		panic("only the token owner can list it")
	}
	if !approved(cid, tid, owner, cur.Address()) {
		panic("approve the market for this token first: core.Approve(cid, tid, " + cur.Address().String() + ")")
	}
	if v := byToken.Get(tokenKey(cid, tid)); v != nil {
		old := mustListing(v.(int64))
		if live(old, cur.Address()) {
			panic("token is already listed as #" + itoa(old.id) + "; use UpdatePrice")
		}
		remove(old, "stale")
	}

	nextID++
	l := &listing{
		id: nextID, cid: cid, tid: tid, seller: seller, price: price,
		moves: core.TokenMoves(cid, tid), height: runtime.ChainHeight(),
	}
	listings.Set(safe.PadInt(l.id, idWidth), l)
	byToken.Set(tokenKey(cid, tid), l.id)
	byCollection.Set(collectionKey(l), l.id)
	bySeller.Set(sellerKey(l), l.id)
	chain.Emit("Listed", "id", itoa(l.id), "cid", cid, "tid", tid, "seller", seller.String(), "price", itoa(price))
	return itoa(l.id)
}

// UpdatePrice changes the price of a live listing; Buy's expectedPrice
// protects buyers from a change racing their purchase (RA M-10).
func UpdatePrice(cur realm, listingID string, price int64) {
	assertNoDeposit(cur)
	assertPrice(price)
	l := mustListing(parseID(listingID))
	assertSeller(cur, l)
	if !live(l, cur.Address()) {
		panic("listing is stale; cancel it and list again")
	}
	byCollection.Remove(collectionKey(l))
	l.price = price
	byCollection.Set(collectionKey(l), l.id)
	chain.Emit("PriceUpdated", "id", listingID, "cid", l.cid, "tid", l.tid, "price", itoa(price))
}

// Cancel removes the caller's listing. Never paused.
func Cancel(cur realm, listingID string) {
	assertNoDeposit(cur)
	l := mustListing(parseID(listingID))
	assertSeller(cur, l)
	remove(l, "cancelled")
}

// CancelStale lets anyone remove a listing that can no longer be bought.
func CancelStale(cur realm, listingID string) {
	assertNoDeposit(cur)
	l := mustListing(parseID(listingID))
	if live(l, cur.Address()) {
		panic("listing is still valid")
	}
	remove(l, "stale")
}

// Buy pays exactly expectedPrice for the listing (excess attached ugnot is
// refunded). Order: checks, remove the listing, move the token, then pay —
// protocol fee to the treasury, royalty to the collection's sub-treasury
// (then distributed to its payees), the rest to the seller. I-4:
// fee + royalty + seller + refund == attached.
func Buy(cur realm, listingID string, expectedPrice int64) {
	paid := received(cur)
	assertTradeOpen()
	buyer := cur.Previous().Address()
	l := mustListing(parseID(listingID))
	if l.price != expectedPrice {
		panic("price is " + itoa(l.price) + "ugnot, expected " + itoa(expectedPrice))
	}
	if paid < l.price {
		panic("send " + itoa(l.price) + "ugnot, sent " + itoa(paid))
	}
	if buyer == l.seller {
		panic("cannot buy your own listing")
	}
	if !live(l, cur.Address()) {
		panic("listing is stale: the token moved or approval was revoked since it was listed")
	}
	remove(l, "sold")

	tok := core.Token(l.cid)
	if err := tok.RealmTeller(0, cur).TransferFrom(0, cur, l.seller, buyer, grc721.TokenID(l.tid)); err != nil {
		panic(err)
	}

	fee := core.FeeConfig()
	protocol := safe.BpsOf(l.price, fee.SecondaryBps)
	royaltyTo, royalty, err := core.Royalty(l.cid).RoyaltyInfo(grc721.TokenID(l.tid), l.price)
	if err != nil {
		panic(err)
	}
	pay(cur, fee.Treasury, protocol)
	pay(cur, royaltyTo, royalty)
	pay(cur, l.seller, l.price-protocol-royalty)
	pay(cur, buyer, paid-l.price)
	if royalty > 0 {
		core.DistributeRoyalties(cross(cur), l.cid)
	}
	chain.Emit("Bought", "id", listingID, "cid", l.cid, "tid", l.tid,
		"seller", l.seller.String(), "buyer", buyer.String(), "price", itoa(l.price),
		"protocolFee", itoa(protocol), "royalty", itoa(royalty))
}

// --- reads ---------------------------------------------------------------------

func Listing(listingID string) string {
	l := mustListing(parseID(listingID))
	w := &safe.JSONWriter{}
	writeListing(w, l)
	return w.String()
}

// ListingOf is the live listing of a token as JSON, or "null".
func ListingOf(cid, tid string) string {
	v := byToken.Get(tokenKey(cid, tid))
	if v == nil {
		return "null"
	}
	l := mustListing(v.(int64))
	if !live(l, selfAddress()) {
		return "null"
	}
	w := &safe.JSONWriter{}
	writeListingLive(w, l, true)
	return w.String()
}

// ActiveListing is the typed read for other realms: the live listing of a
// token, if any.
func ActiveListing(cid, tid string) (id string, price int64, ok bool) {
	v := byToken.Get(tokenKey(cid, tid))
	if v == nil {
		return "", 0, false
	}
	l := mustListing(v.(int64))
	if !live(l, selfAddress()) {
		return "", 0, false
	}
	return itoa(l.id), l.price, true
}

// ListingsByCollection lists by ascending price. Stale listings are
// included with "live":false so pages stay stable; frontends hide them.
func ListingsByCollection(cid string, offset, limit int64) string {
	return listPrefix(&byCollection, cid+":", offset, limit)
}

func ListingsBySeller(seller address, offset, limit int64) string {
	return listPrefix(&bySeller, seller.String()+":", offset, limit)
}

// Floor is the lowest live price in cid, or -1. It inspects at most
// MaxPageSize listings from the cheapest, so spam cannot make it unbounded.
func Floor(cid string) int64 {
	floor := int64(-1)
	seen := 0
	prefix := cid + ":"
	self := selfAddress()
	byCollection.Iterate(prefix, prefixEnd(prefix), func(_ string, v any) bool {
		seen++
		l := mustListing(v.(int64))
		if live(l, self) {
			floor = l.price
			return true
		}
		return seen >= MaxPageSize
	})
	return floor
}

func Render(path string) string {
	return "# market/v1\n\n" + itoa(int64(listings.Size())) + " open listings. " +
		"Read them with `ListingsByCollection` or browse the gallery.\n"
}

// --- internals -------------------------------------------------------------------

// live: still owned by the seller, not moved since listing, still approved.
func live(l *listing, market address) bool {
	owner, err := core.OwnerOf(l.cid, l.tid)
	if err != nil || owner != l.seller {
		return false
	}
	return core.TokenMoves(l.cid, l.tid) == l.moves && approved(l.cid, l.tid, owner, market)
}

func approved(cid, tid string, owner, market address) bool {
	tok := core.Token(cid)
	if tok.IsApprovedForAll(owner, market) {
		return true
	}
	a, err := tok.GetApproved(grc721.TokenID(tid))
	return err == nil && a == market
}

// remove deletes a listing and its indexes; closed listings are not kept
// (RA L-6), the "Cancelled" event (reason sold/cancelled/stale) is the record.
func remove(l *listing, reason string) {
	listings.Remove(safe.PadInt(l.id, idWidth))
	byToken.Remove(tokenKey(l.cid, l.tid))
	byCollection.Remove(collectionKey(l))
	bySeller.Remove(sellerKey(l))
	chain.Emit("Cancelled", "id", itoa(l.id), "cid", l.cid, "tid", l.tid, "reason", reason)
}

func listPrefix(index *avl.Tree, prefix string, offset, limit int64) string {
	if limit <= 0 || limit > MaxPageSize {
		limit = MaxPageSize
	}
	self := selfAddress()
	w := &safe.JSONWriter{}
	w.BeginArray()
	var skipped, written int64
	index.Iterate(prefix, prefixEnd(prefix), func(_ string, v any) bool {
		if skipped < offset {
			skipped++
			return false
		}
		l := mustListing(v.(int64))
		writeListingLive(w, l, live(l, self))
		written++
		return written >= limit
	})
	w.EndArray()
	return w.String()
}

func writeListing(w *safe.JSONWriter, l *listing) {
	writeListingLive(w, l, live(l, selfAddress()))
}

func writeListingLive(w *safe.JSONWriter, l *listing, isLive bool) {
	w.BeginObject()
	w.StrField("id", itoa(l.id))
	w.StrField("cid", l.cid)
	w.StrField("tid", l.tid)
	w.StrField("seller", l.seller.String())
	w.IntField("price", l.price)
	w.IntField("moves", l.moves)
	w.IntField("height", l.height)
	w.BoolField("live", isLive)
	w.EndObject()
}

func mustListing(id int64) *listing {
	v := listings.Get(safe.PadInt(id, idWidth))
	if v == nil {
		panic("unknown listing " + itoa(id))
	}
	return v.(*listing)
}

func assertSeller(cur realm, l *listing) {
	if cur.Previous().Address() != l.seller {
		panic("only the seller can do this")
	}
}

func assertTradeOpen() {
	if core.Paused("trade") {
		panic("paused: trade")
	}
}

func assertPrice(price int64) {
	if price <= 0 || price > types.MaxUnitPrice {
		panic("price must be 1.." + itoa(types.MaxUnitPrice) + " ugnot")
	}
}

func received(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("payments must come directly from a wallet, not through another realm")
	}
	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != "ugnot" && c.Amount != 0 {
			panic("only ugnot is accepted")
		}
	}
	return sent.AmountOf("ugnot")
}

func assertNoDeposit(cur realm) {
	if cur.Previous().IsUserCall() && !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

func pay(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).
		SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

func tokenKey(cid, tid string) string { return cid + ":" + tid }

func collectionKey(l *listing) string {
	return l.cid + ":" + safe.PadInt(l.price, priceWidth) + ":" + safe.PadInt(l.id, idWidth)
}

func sellerKey(l *listing) string { return l.seller.String() + ":" + safe.PadInt(l.id, idWidth) }

// prefixEnd is the smallest key greater than every key with this prefix
// (prefixes here end in ':', so bump it to ';').
func prefixEnd(prefix string) string {
	return prefix[:len(prefix)-1] + string(rune(prefix[len(prefix)-1]+1))
}

func parseID(s string) int64 { return safe.ParseID("listingID", s) }

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// selfAddress is this realm's address for read paths that have no cur.
func selfAddress() address { return chain.PackageAddress(selfPath) }
