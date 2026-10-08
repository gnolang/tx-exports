package drops

import (
	"chain/banker"

	"gno.land/p/samcrew/launchpad/currency/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/nt/grc20reg/v0"
	"gno.land/r/samcrew/launchpad/config/v1"
)

// terms is what this realm needs from config.
type terms struct {
	treasury      address
	primaryFeeBPS int64 // share of each mint price
	collectionFee int64 // in the currency asked for
}

// termsOf reads the terms in force. The collection fee is -1 for a currency
// that has none.
func termsOf(currencyKey string) terms {
	p := config.GetVersion(config.GetCurrentVersion())
	t := terms{treasury: p.Treasury, primaryFeeBPS: p.NFTPrimaryFeeBPS, collectionFee: -1}
	for _, c := range p.Currencies {
		if c.Key == currencyKey {
			t.collectionFee = c.CollectionFee
		}
	}
	return t
}

// policy returns the terms in force after checking that the lane is open for
// the currency. It is a variable only so that unit tests can stand in for the
// config realm, whose admin cannot be set from another package's tests.
var policy = func(lane, currencyKey string) terms {
	config.AssertLaneOpen(lane, currencyKey)
	return termsOf(currencyKey)
}

// balance reads one denomination, so coins of other denominations sent to
// the realm never add to the cost of a payment.
func balance(cur realm, key string) int64 {
	if key == config.NativeCurrency {
		return banker.NewReadonlyBanker().GetCoin(cur.Address(), key)
	}
	return grc20reg.MustGet(key).BalanceOf(cur.Address())
}

// take collects price from the direct caller and returns what the realm held
// before. Native coins come attached: the caller attaches exactly offered, at
// least the price, and the difference goes straight back. A token is pulled
// for exactly the price.
func take(cur realm, key string, price, offered int64) int64 {
	if offered < price {
		panic("launchpad/drops: price above the amount offered")
	}
	if key != config.NativeCurrency {
		held := balance(cur, key)
		if price == 0 {
			currency.AssertNoCoins(0, cur)
		} else {
			currency.CollectToken(0, cur, grc20reg.MustGet(key), price)
		}
		return held
	}
	if offered == 0 {
		currency.AssertNoCoins(0, cur)
		return balance(cur, key)
	}
	buyer := currency.CollectNative(0, cur, offered)
	held := sm.Sub(balance(cur, key), offered)
	pay(cur, key, buyer, offered-price)
	return held
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

// settled aborts the transaction unless everything taken has been paid out:
// the realm must hold exactly what it held before the call.
func settled(cur realm, key string, held int64) {
	if balance(cur, key) != held {
		panic("launchpad/drops: payment not fully settled")
	}
}
