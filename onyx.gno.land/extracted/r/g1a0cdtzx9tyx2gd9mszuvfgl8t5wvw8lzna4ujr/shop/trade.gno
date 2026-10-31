package shop

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/nt/grc721/v0"
)

// List puts tid on sale for price ugnot. The token stays with the owner.
// A dead listing (the recorded seller no longer owns it) is replaced.
func List(cur realm, tid string, price int64) {
	caller := requireUser(cur)
	requireReady()
	if price < 1 {
		panic("market: price")
	}
	id := parseTid(tid)
	if ownerOf(id) != caller {
		panic("market: not owner")
	}
	listings.Set(string(id), listing{Seller: caller, Price: price})
	chain.Emit("List", "tid", string(id), "seller", caller.String(), "price", i64(price))
}

// Cancel removes the caller's listing, or a listing whose seller no longer owns the token.
func Cancel(cur realm, tid string) {
	caller := requireUser(cur)
	requireReady()
	id := parseTid(tid)
	lot := mustListing(id)
	if caller != lot.Seller && caller != ownerOf(id) {
		panic("market: cancel")
	}
	listings.Remove(string(id))
	chain.Emit("Cancel", "tid", string(id), "caller", caller.String())
}

// Buy pays the listing price in ugnot and takes the token.
// The attached send must be exactly the price, one ugnot coin.
func Buy(cur realm, tid string) {
	caller := requireUser(cur)
	requireReady()
	id := parseTid(tid)
	lot := mustListing(id)
	if caller == lot.Seller {
		panic("market: self")
	}
	if ownerOf(id) != lot.Seller {
		panic("market: stale")
	}
	paid := unsafe.OriginSend()
	if len(paid) != 1 || paid[0].Denom != "ugnot" || paid[0].Amount != lot.Price {
		panic("market: pay")
	}
	if err := ledger.TransferFrom(lot.Seller, lot.Seller, caller, id); err != nil {
		panic("market: transfer")
	}
	coins := chain.NewCoins(chain.NewCoin("ugnot", lot.Price))
	bank := banker.NewBanker(banker.BankerTypeOriginSend, cur)
	bank.SendCoins(cur.Address(), lot.Seller, coins)
	listings.Remove(string(id))
	name, _ := metaNameImage(id)
	pushSale(sale{Tid: string(id), Seller: lot.Seller, Buyer: caller, Price: lot.Price, Name: name})
	chain.Emit(
		"Buy",
		"tid", string(id),
		"seller", lot.Seller.String(),
		"buyer", caller.String(),
		"price", i64(lot.Price),
	)
}

func mustListing(id grc721.TokenID) listing {
	got := listings.Get(string(id))
	if got == nil {
		panic("market: no listing")
	}
	return got.(listing)
}

func pushSale(s sale) {
	sales[saleN%saleCap] = s
	saleN++
}
