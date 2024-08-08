// counter-app/r/counter/counter.gno

package codsfjn

import (
	"std"
)


func Mint(addressFrom std.Address, amount1 int64, addressTo std.Address){
	if amount1 <= 0 {
		panic("Amount can't be 0 or less")
	}
	amount1 := 4
	addressTo := g1xdw3r3rmrvdltn3m449m5ess3mchdcxgdckwtk

	//coin := std.NewCoin("ugnot", amount1)

	banker := std.GetBanker(std.BankerTypeRealmIssue)
	banker.IssueCoin(addressTo, "ugnot", amount1)
}