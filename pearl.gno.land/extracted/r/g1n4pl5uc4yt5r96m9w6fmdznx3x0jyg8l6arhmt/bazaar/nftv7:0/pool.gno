package nftv7

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
)

type pool struct {
	gnot   int64
	shares int64
	nfts   int
}

func poolPosKey(slug string, who address) string {
	return slug + ":" + who.String()
}

func DepositPool(cur realm, slug string) {
	caller := requireUser(cur)
	mustCollection(slug)
	sent := unsafe.OriginSend().AmountOf(nativeDenom)
	if sent <= 0 {
		panic("nft: pool deposit")
	}
	p := getPool(slug)
	add := sent
	if p.shares > 0 && p.gnot > 0 {
		add = sent * p.shares / p.gnot
		if add <= 0 {
			add = 1
		}
	}
	p.gnot += sent
	p.shares += add
	pools.Set(slug, p)
	pk := poolPosKey(slug, caller)
	have := int64(0)
	if v := lpPos.Get(pk); v != nil {
		have = v.(int64)
	}
	lpPos.Set(pk, have+add)
	chain.Emit("DepositPool", "slug", slug, "amount", strconv.FormatInt(sent, 10))
	record("depositpool", slug, caller.String(), slug, 0, sent)
}

func WithdrawPool(cur realm, slug string, shares int64) {
	caller := requireUser(cur)
	if shares <= 0 {
		panic("nft: shares")
	}
	p := getPool(slug)
	pk := poolPosKey(slug, caller)
	have := int64(0)
	if v := lpPos.Get(pk); v != nil {
		have = v.(int64)
	}
	if shares > have {
		panic("nft: shares")
	}
	if p.shares <= 0 {
		panic("nft: empty pool")
	}
	out := p.gnot * shares / p.shares
	p.gnot -= out
	p.shares -= shares
	pools.Set(slug, p)
	left := have - shares
	if left <= 0 {
		lpPos.Remove(pk)
	} else {
		lpPos.Set(pk, left)
	}
	if out > 0 {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(self, caller, chain.Coins{{Denom: nativeDenom, Amount: out}})
	}
	chain.Emit("WithdrawPool", "slug", slug, "shares", strconv.FormatInt(shares, 10))
	record("withdrawpool", slug, caller.String(), slug, 0, out)
}

func DepositNftPool(cur realm, id int) {
	caller := requireUser(cur)
	it := mustItem(id)
	if it.listed {
		panic("nft: listed")
	}
	if it.owner != caller {
		panic("nft: not owner")
	}
	grcTransfer(it.collection, caller, caller, self, id)
	it.owner = self
	items.Set(itemKey(id), it)
	nftPos.Set(itemKey(id), caller)
	p := getPool(it.collection)
	p.nfts++
	pools.Set(it.collection, p)
	chain.Emit("DepositNftPool", "id", strconv.Itoa(id), "slug", it.collection)
	record("depositnft", it.collection, caller.String(), it.name, id, 0)
}

func WithdrawNftPool(cur realm, id int) {
	caller := requireUser(cur)
	it := mustItem(id)
	v := nftPos.Get(itemKey(id))
	if v == nil {
		panic("nft: not in pool")
	}
	who := v.(address)
	if who != caller {
		panic("nft: not depositor")
	}
	if it.owner != self || it.listed {
		panic("nft: not in pool")
	}
	grcTransfer(it.collection, self, self, caller, id)
	it.owner = caller
	items.Set(itemKey(id), it)
	nftPos.Remove(itemKey(id))
	p := getPool(it.collection)
	if p.nfts > 0 {
		p.nfts--
	}
	pools.Set(it.collection, p)
	chain.Emit("WithdrawNftPool", "id", strconv.Itoa(id), "slug", it.collection)
	record("withdrawnft", it.collection, caller.String(), it.name, id, 0)
}

func ListPoolNfts(slug string) string {
	mustCollection(slug)
	out := ""
	nftPos.Iterate("", "", func(key string, value any) bool {
		id, err := strconv.Atoi(key)
		if err != nil {
			return false
		}
		it := mustItem(id)
		if it.collection != slug {
			return false
		}
		who := value.(address)
		if out != "" {
			out += "\n"
		}
		out += strconv.Itoa(id) + "|" + it.name + "|" + who.String()
		return false
	})
	return out
}

func PoolOf(slug string) string {
	mustCollection(slug)
	p := getPool(slug)
	return strconv.FormatInt(p.gnot, 10) + "|" + strconv.FormatInt(p.shares, 10) + "|" + strconv.Itoa(p.nfts)
}

func MyPoolShares(slug, who string) int64 {
	v := lpPos.Get(slug + ":" + who)
	if v == nil {
		return 0
	}
	return v.(int64)
}

func getPool(slug string) *pool {
	v := pools.Get(slug)
	if v != nil {
		return v.(*pool)
	}
	return &pool{}
}
