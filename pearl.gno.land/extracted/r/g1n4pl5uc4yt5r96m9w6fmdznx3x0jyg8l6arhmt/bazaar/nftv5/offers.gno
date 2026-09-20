package nftv5

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/fee/v1"
)

type offerRec struct {
	bidder address
	amount int64
}

func offerKey(id int, bidder address) string {
	return strconv.Itoa(id) + ":" + bidder.String()
}

func Offer(cur realm, id int) {
	caller := requireUser(cur)
	it := mustItem(id)
	sent := unsafe.OriginSend().AmountOf(nativeDenom)
	if sent <= 0 {
		panic("nft: offer")
	}
	if caller == it.seller || caller == it.owner {
		panic("nft: self offer")
	}
	key := offerKey(id, caller)
	prev := offers.Get(key)
	if prev != nil {
		old := prev.(*offerRec)
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(self, caller, chain.Coins{{Denom: nativeDenom, Amount: old.amount}})
	}
	offers.Set(key, &offerRec{bidder: caller, amount: sent})
	chain.Emit("Offer", "id", strconv.Itoa(id), "bidder", caller.String(), "amount", strconv.FormatInt(sent, 10))
	record("offer", it.collection, caller.String(), it.name, id, sent)
}

func CancelOffer(cur realm, id int) {
	caller := requireUser(cur)
	key := offerKey(id, caller)
	v := offers.Get(key)
	if v == nil {
		panic("nft: no offer")
	}
	rec := v.(*offerRec)
	offers.Remove(key)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(self, caller, chain.Coins{{Denom: nativeDenom, Amount: rec.amount}})
	it := mustItem(id)
	chain.Emit("CancelOffer", "id", strconv.Itoa(id), "bidder", caller.String())
	record("canceloffer", it.collection, caller.String(), it.name, id, rec.amount)
}

func AcceptOffer(cur realm, id int, bidder address) {
	caller := requireUser(cur)
	it := mustItem(id)
	if it.listed {
		if caller != it.seller {
			panic("nft: not seller")
		}
	} else if caller != it.owner {
		panic("nft: not owner")
	}
	key := offerKey(id, bidder)
	v := offers.Get(key)
	if v == nil {
		panic("nft: no offer")
	}
	rec := v.(*offerRec)
	amt := rec.amount
	offers.Remove(key)
	proto := fee.ProtocolFee(amt, protocolBps)
	royal := int64(0)
	cv := collections.Get(it.collection)
	if cv != nil {
		c := cv.(*collection)
		if c.royaltyBps > 0 {
			royal = fee.ProtocolFee(amt, int64(c.royaltyBps))
		}
	}
	if proto+royal > amt {
		panic("nft: fee")
	}
	pay := amt - proto - royal
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if pay > 0 {
		bk.SendCoins(self, caller, chain.Coins{{Denom: nativeDenom, Amount: pay}})
	}
	if royal > 0 && cv != nil {
		c := cv.(*collection)
		if c.creator.String() != "" {
			bk.SendCoins(self, c.creator, chain.Coins{{Denom: nativeDenom, Amount: royal}})
		}
	}
	fees += proto
	it.listed = false
	it.seller = address("")
	it.price = 0
	it.owner = bidder
	items.Set(itemKey(id), it)
	chain.Emit("AcceptOffer", "id", strconv.Itoa(id), "bidder", bidder.String(), "amount", strconv.FormatInt(amt, 10))
	record("accept", it.collection, bidder.String(), it.name, id, amt)
}

func InstantSell(cur realm, id int) {
	bidder, _, ok := topOfferOf(id)
	if !ok {
		panic("nft: no offer")
	}
	AcceptOffer(cur, id, bidder)
}

func topOfferOf(id int) (address, int64, bool) {
	prefix := strconv.Itoa(id) + ":"
	found := false
	var best address
	bestAmt := int64(0)
	offers.Iterate("", "", func(key string, value any) bool {
		if !strings.HasPrefix(key, prefix) {
			return false
		}
		rec := value.(*offerRec)
		if !found || rec.amount > bestAmt {
			found = true
			best = rec.bidder
			bestAmt = rec.amount
		}
		return false
	})
	return best, bestAmt, found
}

func ListOffers(slug string) string {
	mustCollection(slug)
	out := ""
	offers.Iterate("", "", func(key string, value any) bool {
		rec := value.(*offerRec)
		id := 0
		colon := -1
		for i := 0; i < len(key); i++ {
			if key[i] == ':' {
				colon = i
				break
			}
		}
		if colon <= 0 {
			return false
		}
		id, _ = strconv.Atoi(key[:colon])
		it := mustItem(id)
		if it.collection != slug {
			return false
		}
		if out != "" {
			out += "\n"
		}
		out += strconv.Itoa(id) + "|" + rec.bidder.String() + "|" + strconv.FormatInt(rec.amount, 10) + "|" + it.name
		return false
	})
	return out
}

func CollectionTopOffer(slug string) int64 {
	top := int64(0)
	raw := ListOffers(slug)
	if raw == "" {
		return 0
	}
	lines := strings.Split(raw, "\n")
	for _, line := range lines {
		parts := strings.Split(line, "|")
		if len(parts) < 3 {
			continue
		}
		amt, _ := strconv.ParseInt(parts[2], 10, 64)
		if amt > top {
			top = amt
		}
	}
	return top
}
