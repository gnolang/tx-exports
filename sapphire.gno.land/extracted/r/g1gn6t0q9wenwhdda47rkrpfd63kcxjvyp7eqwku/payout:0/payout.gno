// Forwards whatever ugnot is attached to Forward() on to `to`.
// Deployment plumbing only: it lets funds reach a locally-managed key so
// the real realms can be deployed from disk rather than retyped inline.
package payout

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

func Forward(cur realm, to address) {
	if !to.IsValid() {
		panic("payout: invalid destination")
	}
	amt := unsafe.OriginSend().AmountOf("ugnot")
	if amt <= 0 {
		panic("payout: nothing attached")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin("ugnot", amt)})
}
