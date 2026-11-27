package vault

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

// receivedUgnot returns the amount of ugnot paid to this realm by the current
// transaction. The previous call must be a direct EOA call; payments forwarded
// by an intermediate realm or sent from a MsgRun temporary realm are rejected.
// This is the only file that imports chain/runtime/unsafe, and unsafe is used
// solely to read the envelope amount, never to derive identity.
//
// Parameters:
//   - cur: Realm context.
//
// Returns:
//   - int64: Amount paid in ugnot.
func receivedUgnot(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("payment must come from a direct EOA call")
	}
	return unsafe.OriginSend().AmountOf("ugnot")
}

// payUgnot sends amount ugnot from this realm's address to to.
//
// The banker is created, used and discarded inside this function. It must never
// be stored in state or returned to a caller: BankerTypeRealmSend is a permanent
// spending grant over the realm address, which every vault shares.
//
// Parameters:
//   - cur: Realm context.
//   - to: Recipient address.
//   - amount: Amount in ugnot.
func payUgnot(cur realm, to address, amount int64) {
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
}
