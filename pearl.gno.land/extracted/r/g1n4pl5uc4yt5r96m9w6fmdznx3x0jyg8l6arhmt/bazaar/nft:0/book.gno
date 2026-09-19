package nft

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/fee/v1"
)

const (
	protocolBps = int64(50)
	nativeDenom = "ugnot"
)

func PublicMint(cur realm, slug string) int {
	caller := requireUser(cur)
	col := mustCollection(slug)
	if col.maxSupply <= 0 {
		panic("nft: not a drop")
	}
	if col.minted >= col.maxSupply {
		panic("nft: sold out")
	}
	sent := unsafe.OriginSend()
	if len(sent) > 1 {
		panic("nft: extra denoms")
	}
	if sent.AmountOf(nativeDenom) != col.mintPrice {
		panic("nft: wrong payment")
	}
	n := col.minted + 1
	name := col.name + " #" + strconv.Itoa(n)
	image := "/samples/" + slug + "-0" + strconv.Itoa(n) + ".png"
	if !validImage(image) {
		image = col.cover
	}
	id := mintTo(caller, slug, name, image)
	col.minted++
	collections.Set(slug, col)
	if col.mintPrice > 0 {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(self, col.creator, chain.Coins{{Denom: nativeDenom, Amount: col.mintPrice}})
	}
	chain.Emit("PublicMint", "id", strconv.Itoa(id), "slug", slug, "n", strconv.Itoa(n))
	record("publicmint", slug, caller.String(), name, id, col.mintPrice)
	return id
}

func List(cur realm, id int, priceUgnot int64) {
	caller := requireUser(cur)
	if priceUgnot <= 0 {
		panic("nft: price")
	}
	it := mustItem(id)
	if it.listed {
		panic("nft: listed")
	}
	if it.owner != caller {
		panic("nft: not owner")
	}
	it.listed = true
	it.seller = caller
	it.price = priceUgnot
	it.owner = self
	items.Set(itemKey(id), it)
	chain.Emit("List", "id", strconv.Itoa(id), "seller", caller.String(), "price", strconv.FormatInt(priceUgnot, 10))
	record("list", it.collection, caller.String(), it.name, id, priceUgnot)
}

func Buy(cur realm, id int) {
	caller := requireUser(cur)
	it := mustItem(id)
	if !it.listed {
		panic("nft: not listed")
	}
	sent := unsafe.OriginSend().AmountOf(nativeDenom)
	if sent != it.price {
		panic("nft: wrong payment")
	}
	if caller == it.seller {
		panic("nft: self buy")
	}
	price := it.price
	proto := fee.ProtocolFee(price, protocolBps)
	sellerAmt := price - proto
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if sellerAmt > 0 {
		bk.SendCoins(self, it.seller, chain.Coins{{Denom: nativeDenom, Amount: sellerAmt}})
	}
	fees += proto
	buyer := caller
	it.listed = false
	it.owner = buyer
	it.seller = address("")
	it.price = 0
	items.Set(itemKey(id), it)
	chain.Emit("Buy", "id", strconv.Itoa(id), "buyer", buyer.String(), "fee", strconv.FormatInt(proto, 10))
	record("buy", it.collection, buyer.String(), it.name, id, price)
}

func Cancel(cur realm, id int) {
	caller := requireUser(cur)
	it := mustItem(id)
	if !it.listed {
		panic("nft: not listed")
	}
	if caller != it.seller {
		panic("nft: not seller")
	}
	it.listed = false
	it.owner = it.seller
	it.seller = address("")
	it.price = 0
	items.Set(itemKey(id), it)
	chain.Emit("Cancel", "id", strconv.Itoa(id))
	record("cancel", it.collection, caller.String(), it.name, id, 0)
}

func TransferAdmin(cur realm, next address) {
	caller := requireUser(cur)
	if caller != admin {
		panic("nft: not admin")
	}
	if !next.IsValid() {
		panic("nft: invalid address")
	}
	if next == admin {
		panic("nft: already admin")
	}
	admin = next
	chain.Emit("TransferAdmin", "addr", next.String())
}

func WithdrawFees(cur realm) {
	caller := requireUser(cur)
	if caller != admin {
		panic("nft: not admin")
	}
	if fees <= 0 {
		panic("nft: no fees")
	}
	amt := fees
	fees = 0
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(self, admin, chain.Coins{{Denom: nativeDenom, Amount: amt}})
	chain.Emit("WithdrawFees", "amount", strconv.FormatInt(amt, 10))
}

func ListOpen() string {
	out := ""
	n := 0
	items.Iterate("", "", func(_ string, value any) bool {
		it := value.(*item)
		if !it.listed {
			return false
		}
		if n >= 50 {
			return true
		}
		if out != "" {
			out += "\n"
		}
		out += ItemLine(it.id)
		n++
		return false
	})
	return out
}

func ProtocolBps() int64 {
	return protocolBps
}

func ProtocolFees() int64 {
	return fees
}

func Render(path string) string {
	_ = path
	out := "# Bazaar NFT\n\nMint a unique item, list it at a fixed GNOT price, or buy an open listing.\n\n"
	out += "- items: " + strconv.Itoa(nextID) + "\n"
	out += "- protocol fee: " + strconv.FormatInt(protocolBps, 10) + " bps\n\n"
	open := ListOpen()
	if open == "" {
		out += "_No open listings._\n"
	} else {
		out += "```\n" + open + "\n```\n"
	}
	return out
}
