package bridge 

import (
	"std"
	"strconv"
)

var balances map[std.Address]int64

func init() {
	// Initialize the map
	balances = make(map[std.Address]int64)
}

func Mint(amount1 int64, addressTo std.Address){
	if amount1 <= 0 {
		panic("Amount can't be 0 or less")
	}
	
	//coin := std.NewCoin("GETH", amount1)

	banker := std.GetBanker(std.BankerTypeRealmIssue)
	banker.IssueCoin(addressTo, "geth", amount1)

	balances[addressTo] += amount1
}

func Deposit(amount1 int64, addressFrom std.Address, addressTo std.Address){
	if amount1 <= 0 {
		panic("Amount can't be 0 or less")
	}

	if balances[addressFrom] < amount1 {
		panic("Insufficient minted funds for deposit")
	}

	banker := std.GetBanker(std.BankerTypeOrigSend)
	coin1 := std.NewCoin("geth", amount1)
	banker.SendCoins(addressFrom,std.CurrentRealm().Addr(),std.NewCoins(coin1))

	amount1Str := strconv.FormatInt(amount1,10)

	std.Emit("Deposit", addressFrom.String(), amount1Str)

	banker.RemoveCoin(std.CurrentRealm().Addr(), "geth", amount1)

}

