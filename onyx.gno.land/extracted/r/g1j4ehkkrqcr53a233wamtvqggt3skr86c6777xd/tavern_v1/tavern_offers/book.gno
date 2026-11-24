package tavern_offers

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
)

type itemKey struct{ collection, id string }
type offer struct {
	buyer         address
	amount, nonce int64
}
type listing struct {
	seller       address
	price, nonce int64
}

var offers = make(map[itemKey]offer)
var listings = make(map[itemKey]listing)
var sequence int64
var bookAddress address

func init(cur realm)   { bookAddress = cur.Address() }
func Address() address { return bookAddress }
func fresh() int64     { sequence++; return sequence }

// Limit also keeps basis-point arithmetic within int64 for collection adapters.
const maxAmount = int64(900000000000000)

func caller(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("direct wallet call required")
	}
	return cur.Previous().Address()
}
func unpaid() {
	if len(unsafe.OriginSend()) != 0 {
		panic("unexpected payment")
	}
}
func paid(amount int64) {
	coins := unsafe.OriginSend()
	if amount < 1 || amount > maxAmount || len(coins) != 1 || coins[0].Denom != "ugnot" || coins[0].Amount != amount {
		panic("exact GNOT payment required")
	}
}
func pay(cur realm, to address, amount int64) {
	if amount > 0 {
		banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(Address(), to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
	}
}

func Bid(cur realm, collection, id string, amount, expected int64) {
	runtime.AssertOriginCall()
	buyer := caller(cur)
	paid(amount)
	key := itemKey{collection, id}
	owner := ownerOf(collection, id)
	if owner == buyer || (owner == Address() && listings[key].seller == buyer) {
		panic("cannot bid on own NFT")
	}
	old := offers[key]
	if expected != old.nonce || amount <= old.amount {
		panic("offer changed or too low")
	}
	offers[key] = offer{buyer, amount, fresh()}
	pay(cur, old.buyer, old.amount)
	chain.Emit("OfferPlaced", "collection", collection, "token", id, "amount", strconv.FormatInt(amount, 10))
}

func Cancel(cur realm, collection, id string, expected int64) {
	runtime.AssertOriginCall()
	buyer := caller(cur)
	unpaid()
	key := itemKey{collection, id}
	old := offers[key]
	if old.buyer != buyer || old.nonce != expected {
		panic("offer changed or not yours")
	}
	offers[key] = offer{nonce: fresh()}
	pay(cur, buyer, old.amount)
	chain.Emit("OfferCancelled", "collection", collection, "token", id)
}

// Wallets always bundle Prepare and the owner's direct NFT transfer in one transaction.
// A new owner may replace an abandoned preparation while the NFT is in their wallet.
func Prepare(cur realm, collection, id string) {
	runtime.AssertOriginCall()
	seller := caller(cur)
	unpaid()
	if seller != ownerOf(collection, id) {
		panic("token owner required")
	}
	listings[itemKey{collection, id}] = listing{seller, 0, fresh()}
}
func custody(cur realm, key itemKey) listing {
	l := listings[key]
	if l.seller != caller(cur) || ownerOf(key.collection, key.id) != Address() {
		panic("seller deposit required")
	}
	return l
}

func List(cur realm, collection, id string, price int64) {
	runtime.AssertOriginCall()
	unpaid()
	key := itemKey{collection, id}
	l := custody(cur, key)
	if price < 1 || price > maxAmount {
		panic("invalid price")
	}
	listings[key] = listing{l.seller, price, fresh()}
}

func Withdraw(cur realm, collection, id string) {
	runtime.AssertOriginCall()
	unpaid()
	key := itemKey{collection, id}
	l := custody(cur, key)
	delete(listings, key)
	deliver(cur, collection, id, l.seller)
}

func settle(cur realm, key itemKey, buyer, seller address, gross, minNet int64) {
	if buyer == seller {
		panic("cannot buy own NFT")
	}
	recipient, fee := royalty(key.collection, key.id, gross)
	if fee < 0 || fee > gross || (fee > 0 && !recipient.IsValid()) || gross-fee < minNet {
		panic("invalid settlement terms")
	}
	delete(listings, key)
	deliver(cur, key.collection, key.id, buyer)
	pay(cur, recipient, fee)
	pay(cur, seller, gross-fee)
	chain.Emit("Sale", "collection", key.collection, "token", key.id, "buyer", buyer.String(), "seller", seller.String(), "gross", strconv.FormatInt(gross, 10), "royalty", strconv.FormatInt(fee, 10))
}

func Accept(cur realm, collection, id string, expected, minNet int64) {
	runtime.AssertOriginCall()
	unpaid()
	key := itemKey{collection, id}
	l := custody(cur, key)
	b := offers[key]
	if b.amount == 0 || b.nonce != expected {
		panic("offer changed")
	}
	offers[key] = offer{nonce: fresh()}
	settle(cur, key, b.buyer, l.seller, b.amount, minNet)
}

func Buy(cur realm, collection, id string, expected, price int64) {
	runtime.AssertOriginCall()
	buyer := caller(cur)
	paid(price)
	key := itemKey{collection, id}
	l := listings[key]
	if l.price != price || l.nonce != expected || ownerOf(collection, id) != Address() {
		panic("listing changed")
	}
	b := offers[key]
	offers[key] = offer{nonce: fresh()}
	pay(cur, b.buyer, b.amount)
	settle(cur, key, buyer, l.seller, price, 0)
}

// Numeric values are decimal strings to preserve integer precision in clients.
func Snapshot(collection, id string) string {
	key := itemKey{collection, id}
	owner := ownerOf(collection, id)
	b, l := offers[key], listings[key]
	_, fee := royalty(collection, id, b.amount)
	_, listFee := royalty(collection, id, l.price)
	return strings.Join([]string{
		owner.String(), l.seller.String(), strconv.FormatInt(l.price, 10), strconv.FormatInt(l.nonce, 10),
		b.buyer.String(), strconv.FormatInt(b.amount, 10), strconv.FormatInt(b.nonce, 10),
		strconv.FormatInt(fee, 10), Address().String(), strconv.FormatInt(listFee, 10),
	}, "|")
}
