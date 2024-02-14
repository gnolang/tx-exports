package realmpackagetest

import "std"

func Call() string {
	coin := std.Coin{"leon", 100}
	this := std.GetOrigPkgAddr()
	me := std.GetOrigCaller()

	banker := std.GetBanker(std.BankerTypeRealmIssue)

	banker.IssueCoin(this, coin.Denom, coin.Amount)

	cz := std.Coins{coin}
	banker.SendCoins(this, me, cz)
	return banker.GetCoins(me).String()
}
