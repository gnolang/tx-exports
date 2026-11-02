// Package market is the platform's immutable fixed-price market
// (design §2.5.4). It never holds a token: the seller approves this
// realm in core, the token stays in the seller's wallet, and Buy moves it
// through core's official grc721 RealmTeller in the same transaction that
// pays everyone. It never holds coins either (I-3).
//
// A token has at most one listing, addressed by (cid, tid). Stale listings
// (RA H-2) cannot be bought: a listing pins the token's move counter and
// core's approval nonces at listing time, and Buy requires owner == seller,
// the counter unchanged and the approval it was listed under still in
// place, unchanged (I-8). Once stale, a listing stays dead: approving the
// market again later never revives it (SA-L3). A stale listing never blocks
// the new owner: List overwrites it and anyone may CancelStale it.
//
// Storage (storage-cost-analysis M1-M3): a listing is one packed string in
// `listings` (key cid:tid) plus one key in the price index `byCollection`
// (floor, collection pages). Per-seller history comes from the indexer
// ("Listed"/"Cancelled" events), not from an on-chain index.
//
// Deposit return: gno refunds a freed storage deposit to the signer of the
// transaction that frees it, so a Buy hands the buyer the deposit the
// seller locked for the listing. Buy therefore charges the buyer that
// amount on top of the price and pays it to the seller (ListingDeposit,
// measured). It is exact up to a few bytes because every listing costs the
// same storage objects: a sentinel key keeps both trees non-empty (an avl
// insert into an empty tree creates one node, any later insert two). Net,
// the seller is whole and the buyer pays the price (the chain's refund
// cancels the extra). Not compensated: the deposit of a per-token Approve,
// which the sale's transfer clears (~0.1-0.2 GNOT to the buyer, depending
// on the collection's other pending approvals); an approval-for-all is not
// cleared, so listing under SetApprovalForAll leaves nothing behind.
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
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/v0"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/safe/v1"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/types/v1"
	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia2/core"
)

const (
	MaxPageSize = 50
	priceWidth  = 16 // types.MaxUnitPrice has 16 digits

	// Deposit-return estimate (ugnot), from the bytes measured in this
	// package's z_bytes_* filetests at gno.land's storage price of 100
	// ugnot/byte (vm param storage_price on Onyx and gnoland-1). Re-measure
	// before a deploy to a chain with another price.
	StoragePrice   = 100
	ListingBytes   = 4_070 // one listing: a listings key + a byCollection key, two avl nodes each (measured 4,049-4,101 locked, 4,032-4,091 freed)
	ListingDeposit = ListingBytes * StoragePrice

	// sentinel is a key of both trees that is never a listing (it sorts
	// after every "cid:" prefix range), so neither tree is ever empty.
	sentinel = "~"
)

// listing is the decoded form of one packed `listings` value.
type listing struct {
	cid, tid string
	id       int64
	seller   address
	price    int64
	moves    int64 // core.TokenMoves at listing time
	height   int64
	feeBps   int64 // protocol fee at listing time; a sale never pays more (SA-I5)
	engBps   int64 // engine-author fee at listing time; a sale never pays more
	deposit  int64 // deposit return the buyer pays the seller (ListingDeposit, not stored)
	// approval the listing was made under (SA-L3): per-token and/or
	// approval-for-all, each pinned to core's nonce at listing time
	viaToken, viaAll          bool
	tokenNonce, operatorNonce int64
}

var (
	listings     avl.Tree // cid:tid -> packed listing (encode)
	byCollection avl.Tree // cid:paddedPrice:tid -> "" (floor = first key)
	nextID       int64
	selfPath     string // captured in init for read paths without a cur
)

func init(cur realm) {
	selfPath = cur.PkgPath()
	listings.Set(sentinel, "")
	byCollection.Set(sentinel, "")
}

// List offers a token of a Final collection at price (ugnot). The caller
// must own it and have approved this realm (Approve or SetApprovalForAll in
// core). A stale listing of the same token is replaced. Returns the
// listing's sequence id (events); the listing itself is addressed by
// (cid, tid).
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
	viaToken, viaAll := approvals(cid, tid, owner, cur.Address())
	if !viaToken && !viaAll {
		panic("approve the market for this token first: core.Approve(cid, tid, " + cur.Address().String() + ")")
	}
	if old, ok := lookup(cid, tid); ok {
		if live(old, cur.Address()) {
			panic("token is already listed as #" + itoa(old.id) + "; use UpdatePrice")
		}
		remove(old, "stale")
	}

	nextID++
	tn, on := core.ApprovalNonces(cid, tid, owner, cur.Address())
	_, engBps := core.EngineFee(cid)
	l := &listing{
		cid: cid, tid: tid, id: nextID, seller: seller, price: price,
		moves: core.TokenMoves(cid, tid), height: runtime.ChainHeight(),
		feeBps: core.FeeConfig().SecondaryBps, engBps: engBps,
		viaToken: viaToken, viaAll: viaAll, tokenNonce: tn, operatorNonce: on,
	}
	l.deposit = ListingDeposit
	store(l)
	chain.Emit("Listed", "id", itoa(l.id), "cid", cid, "tid", tid, "seller", seller.String(), "price", itoa(price),
		"deposit", itoa(l.deposit))
	return itoa(l.id)
}

// UpdatePrice changes the price of a live listing; Buy's expectedPrice
// protects buyers from a change racing their purchase (RA M-10).
func UpdatePrice(cur realm, cid, tid string, price int64) {
	assertNoDeposit(cur)
	assertPrice(price)
	l := mustListing(cid, tid)
	assertSeller(cur, l)
	if !live(l, cur.Address()) {
		panic("listing is stale; cancel it and list again")
	}
	byCollection.Remove(collectionKey(l))
	l.price = price
	store(l)
	chain.Emit("PriceUpdated", "id", itoa(l.id), "cid", l.cid, "tid", l.tid, "price", itoa(price))
}

// Cancel removes the caller's listing (its storage deposit returns to the
// caller). Never paused.
func Cancel(cur realm, cid, tid string) {
	assertNoDeposit(cur)
	l := mustListing(cid, tid)
	assertSeller(cur, l)
	remove(l, "cancelled")
}

// CancelStale lets anyone remove a listing that can no longer be bought;
// the freed deposit goes to the caller (gno's rule), a cleanup bounty.
func CancelStale(cur realm, cid, tid string) {
	assertNoDeposit(cur)
	l := mustListing(cid, tid)
	if live(l, cur.Address()) {
		panic("listing is still valid")
	}
	remove(l, "stale")
}

// Buy pays exactly expectedPrice for the token's listing, plus the
// listing's deposit return (see the package doc); excess attached ugnot is
// refunded. Order: checks, remove the listing, move the token, then pay —
// protocol fee to the treasury, royalty to the collection's sub-treasury
// (then distributed to its payees), the engine author's fee, the rest plus
// the deposit return to the seller. I-4: protocol + royalty + engine +
// seller + refund == attached.
func Buy(cur realm, cid, tid string, expectedPrice int64) {
	paid := received(cur)
	assertTradeOpen()
	buyer := cur.Previous().Address()
	l := mustListing(cid, tid)
	if l.price != expectedPrice {
		panic("price is " + itoa(l.price) + "ugnot, expected " + itoa(expectedPrice))
	}
	if paid < l.price+l.deposit {
		panic("send " + itoa(l.price+l.deposit) + "ugnot (price " + itoa(l.price) + " + deposit return " +
			itoa(l.deposit) + "), sent " + itoa(paid))
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

	s := settle(l)
	pay(cur, s.treasury, s.protocol)
	pay(cur, s.royaltyTo, s.royalty)
	pay(cur, s.engineAuthor, s.engine)
	pay(cur, l.seller, s.seller)
	pay(cur, buyer, paid-l.price-l.deposit)
	if s.royalty > 0 {
		core.DistributeRoyalties(cross(cur), l.cid)
	}
	chain.Emit("Bought", "id", itoa(l.id), "cid", l.cid, "tid", l.tid,
		"seller", l.seller.String(), "buyer", buyer.String(), "price", itoa(l.price),
		"protocolFee", itoa(s.protocol), "royalty", itoa(s.royalty), "engineFee", itoa(s.engine),
		"engineAuthor", s.engineAuthor.String(), "deposit", itoa(l.deposit))
}

// settlement is how a sale of l is paid now (I-4: protocol + royalty +
// engine + seller == price + deposit).
type settlement struct {
	treasury, royaltyTo, engineAuthor address
	protocol, royalty, engine, seller int64
}

func settle(l *listing) settlement {
	fee := core.FeeConfig()
	feeBps := fee.SecondaryBps
	if l.feeBps < feeBps {
		feeBps = l.feeBps
	}
	author, engBps := core.EngineFee(l.cid)
	if l.engBps < engBps {
		engBps = l.engBps
	}
	s := settlement{treasury: fee.Treasury, engineAuthor: author}
	s.protocol = safe.BpsOf(l.price, feeBps)
	s.engine = safe.BpsOf(l.price, engBps)
	royaltyTo, royalty, err := core.Royalty(l.cid).RoyaltyInfo(grc721.TokenID(l.tid), l.price)
	if err != nil {
		panic(err)
	}
	s.royaltyTo, s.royalty = royaltyTo, royalty
	s.seller = l.price - s.protocol - s.royalty - s.engine + l.deposit
	return s
}

// --- reads ---------------------------------------------------------------------

// Listing is the token's listing as JSON, stale ones included with
// "live":false, or "null".
func Listing(cid, tid string) string {
	l, ok := lookup(cid, tid)
	if !ok {
		return "null"
	}
	w := &safe.JSONWriter{}
	writeListingLive(w, l, live(l, selfAddress()))
	return w.String()
}

// ListingOf is the live listing of a token as JSON, or "null".
func ListingOf(cid, tid string) string {
	l, ok := lookup(cid, tid)
	if !ok || !live(l, selfAddress()) {
		return "null"
	}
	w := &safe.JSONWriter{}
	writeListingLive(w, l, true)
	return w.String()
}

// ActiveListing is the typed read for other realms: the live listing of a
// token, if any (id is the sequence id).
func ActiveListing(cid, tid string) (id string, price int64, ok bool) {
	l, found := lookup(cid, tid)
	if !found || !live(l, selfAddress()) {
		return "", 0, false
	}
	return itoa(l.id), l.price, true
}

// Quote is what Buy(cid, tid, price) costs and pays now, as JSON: {live,
// id, seller, price, deposit, total (attach this), protocolFee, royalty,
// royaltyTo, engineFee, engineAuthor, sellerProceeds}; "null" if unlisted.
func Quote(cid, tid string) string {
	l, ok := lookup(cid, tid)
	if !ok {
		return "null"
	}
	s := settle(l)
	w := &safe.JSONWriter{}
	w.BeginObject()
	w.BoolField("live", live(l, selfAddress()))
	w.StrField("id", itoa(l.id))
	w.StrField("seller", l.seller.String())
	w.IntField("price", l.price)
	w.IntField("deposit", l.deposit)
	w.IntField("total", l.price+l.deposit)
	w.IntField("protocolFee", s.protocol)
	w.IntField("royalty", s.royalty)
	w.StrField("royaltyTo", s.royaltyTo.String())
	w.IntField("engineFee", s.engine)
	w.StrField("engineAuthor", s.engineAuthor.String())
	w.IntField("sellerProceeds", s.seller)
	w.EndObject()
	return w.String()
}

// ListingsByCollection lists by ascending price. Stale listings are
// included with "live":false so pages stay stable; frontends hide them.
// Listings by seller: use the indexer (Listed / Cancelled events).
func ListingsByCollection(cid string, offset, limit int64) string {
	if limit <= 0 || limit > MaxPageSize {
		limit = MaxPageSize
	}
	prefix := cid + ":"
	self := selfAddress()
	w := &safe.JSONWriter{}
	w.BeginArray()
	var skipped, written int64
	byCollection.Iterate(prefix, prefixEnd(prefix), func(k string, _ any) bool {
		if skipped < offset {
			skipped++
			return false
		}
		l := mustListing(cid, tidOfKey(k))
		writeListingLive(w, l, live(l, self))
		written++
		return written >= limit
	})
	w.EndArray()
	return w.String()
}

// Floor is the lowest live price in cid, or -1. It inspects at most
// MaxPageSize listings from the cheapest, so spam cannot make it unbounded.
func Floor(cid string) int64 {
	floor := int64(-1)
	seen := 0
	prefix := cid + ":"
	self := selfAddress()
	byCollection.Iterate(prefix, prefixEnd(prefix), func(k string, _ any) bool {
		seen++
		l := mustListing(cid, tidOfKey(k))
		if live(l, self) {
			floor = l.price
			return true
		}
		return seen >= MaxPageSize
	})
	return floor
}

func Render(path string) string {
	return "# market/v1\n\n" + itoa(int64(listings.Size()-1)) + " open listings. " +
		"Read them with `ListingsByCollection` or browse the gallery.\n"
}

// --- internals -------------------------------------------------------------------

// live: still owned by the seller, not moved since listing, and the
// approval it was listed under is still in place and untouched since: a
// per-token listing dies with any later Approve of that token, an
// approval-for-all listing with any later SetApprovalForAll of the market
// by the seller — even one that approves again (SA-L3).
func live(l *listing, market address) bool {
	owner, err := core.OwnerOf(l.cid, l.tid)
	if err != nil || owner != l.seller || core.TokenMoves(l.cid, l.tid) != l.moves {
		return false
	}
	viaToken, viaAll := approvals(l.cid, l.tid, owner, market)
	tn, on := core.ApprovalNonces(l.cid, l.tid, owner, market)
	return (l.viaToken && viaToken && tn == l.tokenNonce) || (l.viaAll && viaAll && on == l.operatorNonce)
}

// approvals reports whether market is approved for this token, and whether
// it is approved for all of owner's tokens.
func approvals(cid, tid string, owner, market address) (viaToken, viaAll bool) {
	tok := core.Token(cid)
	a, err := tok.GetApproved(grc721.TokenID(tid))
	return err == nil && a == market, tok.IsApprovedForAll(owner, market)
}

// store writes l and its price-index key.
func store(l *listing) {
	listings.Set(tokenKey(l.cid, l.tid), encode(l))
	byCollection.Set(collectionKey(l), "")
}

// remove deletes a listing and its index key; closed listings are not kept
// (RA L-6), the "Cancelled" event (reason sold/cancelled/stale) is the record.
func remove(l *listing, reason string) {
	listings.Remove(tokenKey(l.cid, l.tid))
	byCollection.Remove(collectionKey(l))
	chain.Emit("Cancelled", "id", itoa(l.id), "cid", l.cid, "tid", l.tid, "reason", reason)
}

// encode packs a listing as one comma-separated string (M1: an inline avl
// value instead of a *listing object, ~1.3 KB less per listing):
// id,seller,price,moves,height,feeBps,engBps,flags,tokenNonce,operatorNonce
// with flags = 1 (per-token) | 2 (for-all).
func encode(l *listing) string {
	flags := int64(0)
	if l.viaToken {
		flags |= 1
	}
	if l.viaAll {
		flags |= 2
	}
	return itoa(l.id) + "," + l.seller.String() + "," + itoa(l.price) + "," + itoa(l.moves) + "," +
		itoa(l.height) + "," + itoa(l.feeBps) + "," + itoa(l.engBps) + "," +
		itoa(flags) + "," + itoa(l.tokenNonce) + "," + itoa(l.operatorNonce)
}

func decode(cid, tid, v string) *listing {
	f := strings.Split(v, ",")
	if len(f) != 10 {
		panic("market: corrupt listing " + cid + ":" + tid)
	}
	n := func(i int) int64 {
		x, err := strconv.ParseInt(f[i], 10, 64)
		if err != nil {
			panic("market: corrupt listing " + cid + ":" + tid)
		}
		return x
	}
	flags := n(7)
	return &listing{
		cid: cid, tid: tid, id: n(0), seller: address(f[1]), price: n(2), moves: n(3), height: n(4),
		feeBps: n(5), engBps: n(6), deposit: ListingDeposit, viaToken: flags&1 != 0, viaAll: flags&2 != 0,
		tokenNonce: n(8), operatorNonce: n(9),
	}
}


func lookup(cid, tid string) (*listing, bool) {
	v := listings.Get(tokenKey(cid, tid))
	if v == nil {
		return nil, false
	}
	return decode(cid, tid, v.(string)), true
}

func mustListing(cid, tid string) *listing {
	l, ok := lookup(cid, tid)
	if !ok {
		panic("token " + cid + ":" + tid + " is not listed")
	}
	return l
}

func writeListingLive(w *safe.JSONWriter, l *listing, isLive bool) {
	w.BeginObject()
	w.StrField("id", itoa(l.id))
	w.StrField("cid", l.cid)
	w.StrField("tid", l.tid)
	w.StrField("seller", l.seller.String())
	w.IntField("price", l.price)
	w.IntField("deposit", l.deposit)
	w.IntField("moves", l.moves)
	w.IntField("height", l.height)
	w.IntField("engineFeeBps", l.engBps)
	w.BoolField("live", isLive)
	w.EndObject()
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
	if to == cur.Address() {
		panic("refusing to pay the market itself: the coins would be stranded (SA-L5)")
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).
		SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}

// tokenKey is the listing key. cid and tid are canonical ids (core
// accepted the token), so the key has one spelling per token.
func tokenKey(cid, tid string) string { return cid + ":" + tid }

// collectionKey orders a collection's listings by price; the tid is the
// part after the last ':'.
func collectionKey(l *listing) string {
	return l.cid + ":" + safe.PadInt(l.price, priceWidth) + ":" + l.tid
}

func tidOfKey(k string) string { return k[strings.LastIndex(k, ":")+1:] }

// prefixEnd is the smallest key greater than every key with this prefix
// (prefixes here end in ':', so bump it to ';').
func prefixEnd(prefix string) string {
	return prefix[:len(prefix)-1] + string(rune(prefix[len(prefix)-1]+1))
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// selfAddress is this realm's address for read paths that have no cur.
func selfAddress() address { return chain.PackageAddress(selfPath) }
