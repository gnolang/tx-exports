// counter-app/r/counter/counter.gno

package contract

import (
	"std"
)


func Mint(addressFrom std.Address, amount1 int64, addressTo std.Address){
	if amount1 <= 0 {
		panic("Amount can't be 0 or less")
	}

	//coin := std.NewCoin("ugnot", amount1)

	banker := std.GetBanker(std.BankerTypeRealmIssue)
	banker.IssueCoin(addressTo, "ugnot", amount1)
}