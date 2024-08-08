package bridge

import (
	"std"
)

var balances map[std.Address]int64

func Mint(amount1 int64, addressTo std.Address) {
	if amount1 <= 0 {
		panic("Amount can't be 0 or less")
	}

	banker := std.GetBanker(std.BankerTypeRealmIssue)
	banker.IssueCoin(addressTo, "geth", amount1)

	balances[addressTo] += amount1
}
