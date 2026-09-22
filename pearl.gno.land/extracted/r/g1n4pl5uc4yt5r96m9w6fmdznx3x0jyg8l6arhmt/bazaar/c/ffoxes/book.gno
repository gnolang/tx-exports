package ffoxes

import (
	"chain"
	"chain/banker"
	"strconv"

	"gno.land/p/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/fee/v1"
	factory "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/factoryv3"
)

const protocolBps = int64(50)

func List(cur realm, id int, priceUgnot int64) {
	caller := requireUser(cur)
	if priceUgnot <= 0 {
		panic("col: price")
	}
	it := mustItem(id)
	if it.listed {
		panic("col: listed")
	}
	if it.owner != caller {
		panic("col: not owner")
	}
	grcTransfer(caller, caller, self, id)
	it.listed = true
	it.seller = caller
	it.price = priceUgnot
	it.owner = self
	items.Set(itemKey(id), it)
	chain.Emit("List", "id", strconv.Itoa(id), "seller", caller.String(), "price", strconv.FormatInt(priceUgnot, 10))
}

func UpdatePrice(cur realm, id int, priceUgnot int64) {
	caller := requireUser(cur)
	if priceUgnot <= 0 {
		panic("col: price")
	}
	it := mustItem(id)
	if !it.listed {
		panic("col: not listed")
	}
	if it.seller != caller {
		panic("col: not seller")
	}
	it.price = priceUgnot
	items.Set(itemKey(id), it)
	chain.Emit("List", "id", strconv.Itoa(id), "seller", caller.String(), "price", strconv.FormatInt(priceUgnot, 10))
}

func Cancel(cur realm, id int) {
	caller := requireUser(cur)
	it := mustItem(id)
	if !it.listed {
		panic("col: not listed")
	}
	if caller != it.seller {
		panic("col: not seller")
	}
	grcTransfer(self, self, it.seller, id)
	it.listed = false
	it.owner = it.seller
	it.seller = address("")
	it.price = 0
	items.Set(itemKey(id), it)
	chain.Emit("Cancel", "id", strconv.Itoa(id))
}

func Buy(cur realm, id int) {
	caller := requireUser(cur)
	it := mustItem(id)
	if !it.listed {
		panic("col: not listed")
	}
	takeExact(it.price)
	if caller == it.seller {
		panic("col: self buy")
	}
	price := it.price
	proto := fee.ProtocolFee(price, protocolBps)
	royal := int64(0)
	if royaltyBps > 0 {
		royal = fee.ProtocolFee(price, int64(royaltyBps))
	}
	if proto+royal > price {
		panic("col: fee")
	}
	sellerAmt := price - proto - royal
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if sellerAmt > 0 {
		bk.SendCoins(self, it.seller, chain.Coins{{Denom: nativeDenom, Amount: sellerAmt}})
	}
	if royal > 0 {
		bk.SendCoins(self, creator, chain.Coins{{Denom: nativeDenom, Amount: royal}})
	}
	if proto > 0 {
		bk.SendCoins(self, factory.Address(), chain.Coins{{Denom: nativeDenom, Amount: proto}})
	}
	grcTransfer(self, self, caller, id)
	it.listed = false
	it.owner = caller
	it.seller = address("")
	it.price = 0
	items.Set(itemKey(id), it)
	chain.Emit("Buy", "id", strconv.Itoa(id), "buyer", caller.String(), "fee", strconv.FormatInt(proto, 10))
}

func Transfer(cur realm, to address, id int) {
	caller := requireUser(cur)
	if !to.IsValid() {
		panic("col: invalid address")
	}
	if to == caller || to == self {
		panic("col: invalid address")
	}
	it := mustItem(id)
	if it.listed {
		panic("col: listed")
	}
	if it.owner != caller {
		panic("col: not owner")
	}
	grcTransfer(caller, caller, to, id)
	it.owner = to
	items.Set(itemKey(id), it)
	chain.Emit("Transfer", "id", strconv.Itoa(id), "to", to.String())
}

func ProtocolBps() int64 {
	return protocolBps
}

func grcTransfer(spender, from, to address, id int) {
	err := ledger.TransferFrom(spender, from, to, itemTid(id))
	if err != nil {
		panic("col: transfer")
	}
}
