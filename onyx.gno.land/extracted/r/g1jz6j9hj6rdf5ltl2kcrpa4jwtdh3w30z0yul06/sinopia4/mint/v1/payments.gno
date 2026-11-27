package mint

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

// I-3: this realm holds no balance. Each paying function receives the
// attached ugnot and pushes every unit out before returning: protocol fee,
// creator payees, and the refund. Nothing is ever kept for later.

// received returns the ugnot attached to a direct wallet call. Payments are
// accepted only when a wallet called us: the origin-send envelope is shared
// by every realm on the path, so a realm in between could have consumed it
// (chain/runtime/unsafe.OriginSend).
func received(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("payments must come directly from a wallet, not through another realm")
	}
	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != "ugnot" && c.Amount != 0 {
			panic("only ugnot is accepted")
		}
	}
	return sent.AmountOf("ugnot")
}

// assertNoDeposit refuses coins on functions that take none (RA L-1).
func assertNoDeposit(cur realm) {
	if cur.Previous().IsUserCall() && !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

func pay(cur realm, to address, amount int64) {
	if amount <= 0 {
		return
	}
	if to == cur.Address() {
		panic("refusing to pay the minter itself: the coins would be stranded (SA-L5)")
	}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).
		SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}
