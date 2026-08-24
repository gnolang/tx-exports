// A testnet utility: forward attached coins to an arbitrary address.
//
// It exists because the agent tooling can only send between its own
// named keys, and that set is capped -- so there was no way to put gas
// into a throwaway wallet created outside it. This is the smallest thing
// that closes that gap.
//
// It holds nothing. Coins arrive with the call and leave inside the same
// call; if the send fails the whole transaction reverts and the coins
// were never anywhere. There is no balance to withdraw, no owner, and
// no state -- which is deliberate, because a utility that CAN hold funds
// is a utility somebody eventually leaves funds in.
package ugnotforward

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

func Forward(cur realm, to address) string {
	if !to.IsValid() {
		panic("ugnotforward: invalid destination")
	}
	sent := unsafe.OriginSend()
	amt := sent.AmountOf("ugnot")
	if amt <= 0 {
		panic("ugnotforward: attach some ugnot")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin("ugnot", amt)})
	return "forwarded"
}

func Render(path string) string {
	return "Attach ugnot, name a destination, the coins leave in the same call. Holds nothing."
}
