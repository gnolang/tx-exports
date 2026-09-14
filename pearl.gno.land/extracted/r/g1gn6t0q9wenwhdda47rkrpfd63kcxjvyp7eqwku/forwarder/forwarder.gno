// Package forwarder is a throwaway Pearl-testnet utility: forwards
// whatever ugnot is attached to a call straight to an arbitrary address.
// Exists purely because no available tool could send ugnot to a derived
// realm address (only between named agent keys) -- same
// attach-then-BankerTypeRealmSend pattern MintAssembled already uses to
// relay mint payments to the collection owner. See conversation history
// (2026-09-14) for why: funding gems/stable's own account so it can pay
// its own storage deposit when RecordMint writes new ownership data.
package forwarder

import (
	"chain/banker"
	unsaferealm "chain/runtime/unsafe"
)

func Forward(cur realm, to address) {
	got := unsaferealm.OriginSend()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, got)
}
