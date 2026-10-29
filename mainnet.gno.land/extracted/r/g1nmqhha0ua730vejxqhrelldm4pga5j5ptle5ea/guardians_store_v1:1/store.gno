package guardians_store_v1

// UNDEPLOYED. Selected inventory only; no minting or operator-transfer rights.
import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	guardians "gno.land/r/g1nmqhha0ua730vejxqhrelldm4pga5j5ptle5ea/guardians"
)

const Seller address = "g1a72vne647vcw9uv0gy7wn8sw8ffc66agl4jdr3"
const RoyaltyReceiver address = "g1lp547ww848djw0ammpqswegg7tc6xczqqtx07n"
const RoyaltyBps = int64(400)
const maxPrice = int64(9000000000000000) // multiplication by 400 stays in int64

type order struct {
	nonce  int64
	price  int64
	active bool
}

var orders = make(map[string]*order)
var nextNonce int64
var storeAddress address
var paused = true

func init(cur realm)   { storeAddress = cur.Address() }
func Address() address { return storeAddress }
func Version() string  { return "guardians.selected-store.v1" }
func Paused() bool     { return paused }
func NextNonce() int64 { return nextNonce + 1 }
func Identity() string {
	return `{"version":"` + Version() + `","seller":"` + Seller.String() + `","royaltyReceiver":"` + RoyaltyReceiver.String() + `","royaltyBps":400,"address":"` + storeAddress.String() + `","paused":` + strconv.FormatBool(paused) + `}`
}

// Public catalogue contains only active orders, never private seller inventory.
// A fresh Snapshot and Buy recheck custody before any wallet signs or settles.
func Listings() string {
	rows := []string{}
	for n := 1; n <= 3333; n++ {
		id := strconv.Itoa(n)
		o := orders[id]
		if o != nil && o.active {
			rows = append(rows, `{"tokenId":`+id+`,"nonce":`+strconv.FormatInt(o.nonce, 10)+`,"priceUgnot":`+strconv.FormatInt(o.price, 10)+`}`)
		}
	}
	return "[" + strings.Join(rows, ",") + "]"
}
func Snapshot(id string) string {
	n, err := strconv.Atoi(id)
	if err != nil || n < 1 || n > 3333 || strconv.Itoa(n) != id {
		panic("store: invalid token ID")
	}
	o := orders[id]
	base := `{"tokenId":` + id + `,"owner":"` + guardians.OwnerOf(id).String() + `","paused":` + strconv.FormatBool(paused)
	if o == nil {
		return base + `,"registered":false,"active":false,"nonce":0,"priceUgnot":0}`
	}
	return base + `,"registered":true,"active":` + strconv.FormatBool(o.active) + `,"nonce":` + strconv.FormatInt(o.nonce, 10) + `,"priceUgnot":` + strconv.FormatInt(o.price, 10) + `}`
}
func HasOrder(id string) bool    { return orders[id] != nil }
func OrderNonce(id string) int64 { return mustOrder(id).nonce }
func OrderPrice(id string) int64 { return mustOrder(id).price }
func IsListed(id string) bool {
	o := orders[id]
	return o != nil && o.active && guardians.OwnerOf(id) == storeAddress
}

// Register BEFORE the seller directly transfers a selected NFT to this realm.
// The store cannot pull NFTs out of the seller's wallet.
func Register(cur realm, id string) {
	onlySeller(cur)
	noPayment()
	n, err := strconv.Atoi(id)
	if err != nil || n < 1 || n > 3333 || strconv.Itoa(n) != id {
		panic("store: invalid token ID")
	}
	if HasOrder(id) {
		panic("store: already registered")
	}
	if guardians.OwnerOf(id) != Seller {
		panic("store: seller does not own token")
	}
	orders[id] = &order{nonce: freshNonce()}
	chain.Emit("StoreRegistered", "tokenId", id)
}

// Explicit positive price only. No default price and no free checkout.
func List(cur realm, id string, price, expectedNonce int64) {
	onlySeller(cur)
	noPayment()
	o := currentOrder(id, expectedNonce)
	if guardians.OwnerOf(id) != storeAddress {
		panic("store: token is not deposited")
	}
	if price < 1 || price > maxPrice {
		panic("store: invalid price")
	}
	verifyRoyalty(id, price)
	o.price = price
	o.active = true
	o.nonce = freshNonce()
	chain.Emit("StoreListed", "tokenId", id, "price", strconv.FormatInt(price, 10), "nonce", strconv.FormatInt(o.nonce, 10))
}

func Unlist(cur realm, id string, expectedNonce int64) {
	onlySeller(cur)
	noPayment()
	o := currentOrder(id, expectedNonce)
	o.active = false
	o.nonce = freshNonce()
	chain.Emit("StoreUnlisted", "tokenId", id)
}

// Returns selected, unsold inventory even while globally paused. An undeployed
// or unapproved realm must NEVER receive real NFTs.
func Withdraw(cur realm, id string, expectedNonce int64) {
	onlySeller(cur)
	noPayment()
	currentOrder(id, expectedNonce)
	owner := guardians.OwnerOf(id)
	if owner != storeAddress && owner != Seller {
		panic("store: inventory owner changed")
	}
	delete(orders, id)
	if owner == storeAddress {
		guardians.TransferFrom(cross(cur), storeAddress, Seller, id)
	}
	chain.Emit("StoreWithdrawn", "tokenId", id)
}

func SetPaused(cur realm, value bool) {
	onlySeller(cur)
	noPayment()
	paused = value
	chain.Emit("StorePaused", "paused", strconv.FormatBool(value))
}

// One MsgCall settles the NFT and both payouts. Any abort rolls back the tx.
// Expected nonce AND price stop a stale checkout accepting edited terms.
func Buy(cur realm, id string, expectedNonce, expectedPrice int64) {
	directUser(cur)
	if paused {
		panic("store: paused")
	}
	buyer := cur.Previous().Address()
	if buyer == Seller {
		panic("store: seller cannot buy")
	}
	o := currentOrder(id, expectedNonce)
	if !o.active || o.price < 1 {
		panic("store: not listed")
	}
	if o.price != expectedPrice {
		panic("store: price changed")
	}
	if guardians.OwnerOf(id) != storeAddress {
		panic("store: inventory owner changed")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount != o.price {
		panic("store: exact payment required")
	}
	fee := verifyRoyalty(id, o.price)
	price := o.price
	delete(orders, id)
	guardians.TransferFrom(cross(cur), storeAddress, buyer, id)
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(storeAddress, Seller, chain.NewCoins(chain.NewCoin("ugnot", price-fee)))
	if fee > 0 {
		b.SendCoins(storeAddress, RoyaltyReceiver, chain.NewCoins(chain.NewCoin("ugnot", fee)))
	}
	chain.Emit("StorePurchased", "tokenId", id, "buyer", buyer.String(), "price", strconv.FormatInt(price, 10), "royalty", strconv.FormatInt(fee, 10), "nonce", strconv.FormatInt(expectedNonce, 10))
}

func verifyRoyalty(id string, price int64) int64 {
	receiver, bps := guardians.DefaultRoyalty()
	actualReceiver, fee := guardians.RoyaltyInfo(id, price)
	if receiver != RoyaltyReceiver || bps != RoyaltyBps || actualReceiver != RoyaltyReceiver || fee != price*RoyaltyBps/10000 {
		panic("store: royalty policy changed")
	}
	return fee
}
func mustOrder(id string) *order {
	o := orders[id]
	if o == nil {
		panic("store: order not found")
	}
	return o
}
func currentOrder(id string, nonce int64) *order {
	o := mustOrder(id)
	if o.nonce != nonce {
		panic("store: stale order")
	}
	return o
}
func freshNonce() int64 {
	if nextNonce >= 9223372036854775806 {
		panic("store: nonce exhausted")
	}
	nextNonce++
	return nextNonce
}
func directUser(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("store: direct user required")
	}
}
func onlySeller(cur realm) {
	directUser(cur)
	if cur.Previous().Address() != Seller {
		panic("store: seller only")
	}
}
func noPayment() {
	if len(unsafe.OriginSend()) != 0 {
		panic("store: no payment expected")
	}
}
