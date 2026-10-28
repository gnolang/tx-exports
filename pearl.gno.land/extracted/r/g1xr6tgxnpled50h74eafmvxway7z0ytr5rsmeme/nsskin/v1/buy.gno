package nsskin

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v1"
)

const ugnot = "ugnot"

/*
BUYING ONE, AND WEARING IT, IN A SINGLE TRANSACTION.

Splitting these would mean a buyer signs twice and can stop between —
leaving a skin they paid for sitting unworn in a wallet, which is the
state nobody wants and the one a two-step flow produces most often. So
the name is an argument: pass it and the skin is minted and attached
together; pass "" and it is minted loose, which is what somebody buying
ahead of registering a name needs.

NOTHING IS EVER HELD. Payment, treasury and refund all settle inside the
buyer's own transaction, exactly as nslogic does it — and for the same
reason, which is worth restating because it is a legal position rather
than a style: a realm you can have a BALANCE in is a different kind of
thing to operate, subject to different rules, run by people with
licences. Every ugnot that arrives leaves again in the same call.

THE 70/30 SPLIT IS NOT HERE, and that is deliberate rather than
forgotten. Every skin in this collection is ours, so the artist and the
treasury are the same address and a split would move money from a
pocket to itself while costing gas to do it. The artist is recorded on
every definition so the day it stops being us, this is where the split
goes — see SKINS.md.
*/
func Buy(cur realm, id, label, domain string) string {
	if !cur.Previous().IsUserCall() {
		panic("nsskin: only direct wallet calls may attach payment")
	}
	buyer := cur.Previous().Address()
	s := mustSkin(id)
	if s.withdrawn {
		panic("nsskin: " + id + " has been withdrawn and is not for sale")
	}
	// Refuse the sale rather than the attach. Minting a locked skin to
	// somebody who wanted it for a name it will never go on is a refund
	// request wearing the clothes of a successful purchase.
	if label != "" && s.lock != "" && s.lock != domain {
		panic(ufmt.Sprintf("nsskin: %s only goes on *%s names, not *%s", id, s.lock, domain))
	}

	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != ugnot {
			panic("nsskin: only ugnot is accepted, got: " + c.Denom)
		}
	}
	paid := sent.AmountOf(ugnot)
	if paid < price {
		panic(ufmt.Sprintf("nsskin: insufficient payment: need %d ugnot, got %d", price, paid))
	}

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	me := cur.Address()
	if price > 0 {
		b.SendCoins(me, nsdata.GetTreasury(), chain.Coins{chain.NewCoin(ugnot, price)})
	}
	if excess := paid - price; excess > 0 {
		b.SendCoins(me, buyer, chain.Coins{chain.NewCoin(ugnot, excess)})
	}

	s.minted++
	tid := ufmt.Sprintf("%s#%d", id, s.minted)
	if err := nft.Mint(buyer, grcID(tid)); err != nil {
		panic("nsskin: mint failed: " + err.Error())
	}
	tokenSkin.Set(tid, id)

	if label != "" {
		wear(cur, tid, label, domain, buyer)
	}
	return tid
}

// SetPrice is in ugnot, because that is what the chain moves. What it is
// worth in anything else is a question for the page that quotes it, and
// pinning a dollar figure into a contract that cannot see an exchange
// rate would be a lie with a number in it.
func SetPrice(cur realm, p int64) {
	assertIsAdmin(cur)
	if p < 0 {
		panic("nsskin: a negative price is not a discount")
	}
	price = p
}

func GetPrice() int64 { return price }

// Free calls must not be able to strand coins here. This realm has no
// withdrawal path, so anything attached to one would sit in its address
// permanently.
func assertNoSend(cur realm) {
	if !cur.Previous().IsUserCall() {
		return
	}
	if len(unsafe.OriginSend()) > 0 {
		panic("nsskin: this call takes no payment")
	}
}
