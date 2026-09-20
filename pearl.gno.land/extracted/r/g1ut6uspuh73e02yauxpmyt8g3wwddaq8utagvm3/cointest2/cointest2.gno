// Realm cointest2 corrects cointest's MintAndSend: on-chain, IssueCoin
// requires the fully-qualified denom "/<pkgpath>:<sub>" (the local test
// harness accepted a bare subdenom — documented harness/chain
// discrepancy). Throwaway validation helper; safe to abandon.
package cointest2

import (
	"chain"
	"chain/banker"
)

// FullDenom is the chain-qualified denomination this realm issues.
const FullDenom = "/gno.land/r/g1ut6uspuh73e02yauxpmyt8g3wwddaq8utagvm3/cointest2:junk"

// MintAndSend issues amount of FullDenom and force-sends it to target.
func MintAndSend(cur realm, target address, amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}
	bk := banker.NewBanker(banker.BankerTypeRealmIssue, cur)
	bk.IssueCoin(cur.Address(), FullDenom, amount)
	bk.SendCoins(cur.Address(), target, chain.Coins{chain.NewCoin(FullDenom, amount)})
}
