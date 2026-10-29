package leon

import (
	"std"
)

const (
	denom = "leon"
)

var (
	roBank std.Banker
	this   std.Realm
)

func init() {
	roBank = std.GetBanker(std.BankerTypeReadonly)
	this = std.CurrentRealm()
	bank := std.GetBanker(std.BankerTypeRealmIssue)
	bank.IssueCoin(this.Addr(), denom, 100)
}

func Render(_ string) string {
	balance := roBank.GetCoins(this.Addr())

	return balance.String()
}
