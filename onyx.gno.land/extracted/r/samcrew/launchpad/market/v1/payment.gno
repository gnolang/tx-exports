package market

import (
	"chain"
	"chain/banker"
	"strconv"

	"gno.land/p/samcrew/launchpad/currency/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/nt/grc20reg/v0"
	"gno.land/r/samcrew/launchpad/config/v1"
	"gno.land/r/samcrew/launchpad/nft/v1"
)

// escrow is, per currency, the total of open offers: everything this realm
// owes. Currencies are few (config allows sixteen), so a map is enough.
var escrow = map[string]int64{}

// terms is what this realm needs from config.
type terms struct {
	treasury address
	feeBPS   int64 // protocol share of each sale price
}

// policy returns the current terms after checking that the market lane is
// open for the currency. It is a variable only so that unit tests can stand in
// for the config realm, whose admin cannot be set from another package's tests.
var policy = func(currencyKey string) terms {
	config.AssertLaneOpen(config.LaneNFTMarket, currencyKey)
	p := config.GetVersion(config.GetCurrentVersion())
	return terms{treasury: p.Treasury, feeBPS: p.NFTSecondaryFeeBPS}
}

func balance(cur realm, key string) int64 {
	if key == config.NativeCurrency {
		return banker.NewReadonlyBanker().GetCoin(cur.Address(), key)
	}
	return grc20reg.MustGet(key).BalanceOf(cur.Address())
}

// surplus is what the realm holds beyond its open offers. Every entry point
// must leave it exactly as it found it.
func surplus(cur realm, key string) int64 { return sm.Sub(balance(cur, key), escrow[key]) }

// take collects exactly amount from the direct caller, attached for native
// coins and pulled for a token, and returns the surplus before the payment.
func take(cur realm, key string, amount int64) int64 {
	if key == config.NativeCurrency {
		currency.CollectNative(0, cur, amount)
		return sm.Sub(surplus(cur, key), amount)
	}
	before := surplus(cur, key)
	currency.CollectToken(0, cur, grc20reg.MustGet(key), amount)
	return before
}

// untouched is take for an entry point that receives nothing.
func untouched(cur realm, key string) int64 {
	currency.AssertNoCoins(0, cur)
	return surplus(cur, key)
}

func pay(cur realm, key string, to address, amount int64) {
	if amount == 0 {
		return
	}
	if key == config.NativeCurrency {
		currency.PayNative(0, cur, to, amount)
	} else {
		currency.PayToken(0, cur, grc20reg.MustGet(key), to, amount)
	}
}

// settle splits a sale price: the protocol fee to the treasury, each royalty
// to its receiver, the rest, rounding included, to the seller.
func settle(cur realm, key, collection string, price, feeBPS int64, seller, treasury address) {
	fee := sm.BPS(price, feeBPS)
	rest := sm.Sub(price, fee)
	pay(cur, key, treasury, fee)
	var royalties int64
	for _, r := range nft.RoyaltyQuote(collection, price) {
		pay(cur, key, r.Account, r.Amount)
		rest = sm.Sub(rest, r.Amount)
		royalties += r.Amount
	}
	pay(cur, key, seller, rest)
	chain.Emit("Settled", "collection", collection, "currency", key,
		"price", strconv.FormatInt(price, 10), "seller", strconv.FormatInt(rest, 10),
		"fee", strconv.FormatInt(fee, 10), "royalties", strconv.FormatInt(royalties, 10))
}

// settled aborts the transaction unless the realm holds exactly its open
// offers plus the surplus it had before the call: nothing taken is left
// behind, and nothing owed has been spent.
func settled(cur realm, key string, before int64) {
	if surplus(cur, key) != before {
		panic("launchpad/market: payment not fully settled")
	}
}
