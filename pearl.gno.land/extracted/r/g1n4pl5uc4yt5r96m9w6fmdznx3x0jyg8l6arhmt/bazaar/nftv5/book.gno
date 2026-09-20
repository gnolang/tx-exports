package nftv5

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/fee/v1"
)

const sweepCap = 10

const (
	protocolBps = int64(50)
	nativeDenom = "ugnot"
)

func takeLaunchFee() {
	sent := unsafe.OriginSend()
	if len(sent) > 1 {
		panic("nft: extra denoms")
	}
	if sent.AmountOf(nativeDenom) != launchFee {
		panic("nft: launch fee")
	}
	fees += launchFee
}

func PublicMint(cur realm, slug string) int {
	caller := requireUser(cur)
	col := mustCollection(slug)
	if !col.drop {
		panic("nft: not a drop")
	}
	if col.paused {
		panic("nft: paused")
	}
	if col.maxSupply > 0 && col.minted >= col.maxSupply {
		panic("nft: sold out")
	}
	requireAllow(slug, caller)
	checkMintCap(slug, caller)
	pay := col.mintPrice
	if col.wlSupply > 0 && col.minted < col.wlSupply {
		pay = col.wlPrice
	}
	sent := unsafe.OriginSend()
	if len(sent) > 1 {
		panic("nft: extra denoms")
	}
	if sent.AmountOf(nativeDenom) != pay {
		panic("nft: wrong payment")
	}
	n := col.minted + 1
	name := col.name + " #" + strconv.Itoa(n)
	image := "/samples/" + slug + "-0" + strconv.Itoa(n) + ".png"
	if !validImage(image) {
		image = col.cover
	}
	var slot *dropSlot
	if col.loaded > 0 {
		if col.minted >= col.loaded {
			panic("nft: no slot")
		}
		v := dropSlots.Get(slotKey(slug, col.minted))
		if v == nil {
			panic("nft: no slot")
		}
		slot = v.(*dropSlot)
		name = slot.name
		image = slot.image
	}
	mintName := name
	mintImage := image
	if slot != nil && col.hidden {
		mintName = "Unrevealed"
		mintImage = col.cover
	}
	id := mintTo(caller, slug, mintName, mintImage)
	if slot != nil {
		if col.hidden {
			hideMint(id, col.minted, col.cover)
		} else {
			applySlot(id, slot)
		}
	}
	col.minted++
	collections.Set(slug, col)
	noteMint(slug, caller)
	if pay > 0 {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(self, col.creator, chain.Coins{{Denom: nativeDenom, Amount: pay}})
	}
	chain.Emit("PublicMint", "id", strconv.Itoa(id), "slug", slug, "n", strconv.Itoa(n))
	record("publicmint", slug, caller.String(), mintName, id, pay)
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

func UpdatePrice(cur realm, id int, priceUgnot int64) {
	caller := requireUser(cur)
	if priceUgnot <= 0 {
		panic("nft: price")
	}
	it := mustItem(id)
	if !it.listed {
		panic("nft: not listed")
	}
	if it.seller != caller {
		panic("nft: not seller")
	}
	it.price = priceUgnot
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
	fillBuy(cur, caller, id)
}

func Sweep(cur realm, ids string) {
	caller := requireUser(cur)
	parsed := parseIdList(ids)
	if len(parsed) < 1 || len(parsed) > sweepCap {
		panic("nft: sweep")
	}
	total := int64(0)
	for i, id := range parsed {
		for j := 0; j < i; j++ {
			if parsed[j] == id {
				panic("nft: sweep")
			}
		}
		it := mustItem(id)
		if !it.listed {
			panic("nft: not listed")
		}
		if caller == it.seller {
			panic("nft: self buy")
		}
		if it.price <= 0 {
			panic("nft: price")
		}
		total += it.price
	}
	sent := unsafe.OriginSend().AmountOf(nativeDenom)
	if sent != total {
		panic("nft: wrong payment")
	}
	for _, id := range parsed {
		fillBuy(cur, caller, id)
	}
	chain.Emit("Sweep", "n", strconv.Itoa(len(parsed)), "amount", strconv.FormatInt(total, 10))
}

func fillBuy(cur realm, buyer address, id int) {
	it := mustItem(id)
	if !it.listed {
		panic("nft: not listed")
	}
	if buyer == it.seller {
		panic("nft: self buy")
	}
	price := it.price
	proto := fee.ProtocolFee(price, protocolBps)
	royal := int64(0)
	cv := collections.Get(it.collection)
	if cv != nil {
		c := cv.(*collection)
		if c.royaltyBps > 0 {
			royal = fee.ProtocolFee(price, int64(c.royaltyBps))
		}
	}
	if proto+royal > price {
		panic("nft: fee")
	}
	sellerAmt := price - proto - royal
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if sellerAmt > 0 {
		bk.SendCoins(self, it.seller, chain.Coins{{Denom: nativeDenom, Amount: sellerAmt}})
	}
	if royal > 0 && cv != nil {
		c := cv.(*collection)
		if c.creator.String() != "" {
			bk.SendCoins(self, c.creator, chain.Coins{{Denom: nativeDenom, Amount: royal}})
		}
	}
	fees += proto
	it.listed = false
	it.owner = buyer
	it.seller = address("")
	it.price = 0
	items.Set(itemKey(id), it)
	chain.Emit("Buy", "id", strconv.Itoa(id), "buyer", buyer.String(), "fee", strconv.FormatInt(proto, 10))
	record("buy", it.collection, buyer.String(), it.name, id, price)
}

func parseIdList(s string) []int {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			panic("nft: sweep")
		}
		id, err := strconv.Atoi(p)
		if err != nil || id <= 0 {
			panic("nft: sweep")
		}
		out = append(out, id)
	}
	return out
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
