// Realm cointest is a throwaway deployment-validation helper for the
// vault realm. It creates the two out-of-band conditions the vault's
// surplus machinery must handle — a direct bank send of ugnot and a
// foreign denomination — and exercises the vault's realm-caller
// rejection. Not part of the product; safe to abandon after validation.
package cointest

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"

	vault "gno.land/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/vault"
)

var issued string // chain-qualified denom minted by MintAndSend

// ForwardUgnot forwards the ugnot attached to this call to target via a
// plain bank send — out-of-band relative to target's own deposit flow.
func ForwardUgnot(cur realm, target address) {
	if !cur.Previous().IsUserCall() {
		panic("EOA only")
	}
	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		panic("attach coins to forward")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), target, sent)
}

// MintAndSend issues amount of this realm's own denomination and
// force-sends it to target, recording the chain-qualified denom.
func MintAndSend(cur realm, target address, amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmIssue, cur)
	bk.IssueCoin(cur.Address(), "junk", amount)
	for _, c := range bk.GetCoins(cur.Address()) {
		if c.Denom != "ugnot" {
			issued = c.Denom
			bk.SendCoins(cur.Address(), target, chain.Coins{c})
			return
		}
	}
	panic("no issued denom found")
}

// Issued returns the denom minted by MintAndSend.
func Issued() string { return issued }

// TryDeposit attempts a realm-to-realm call of vault.Deposit. The vault
// must reject it (IsUserCall guard), aborting this whole transaction —
// success of this function would be a security regression.
func TryDeposit(cur realm) {
	vault.Deposit(cross(cur))
}
