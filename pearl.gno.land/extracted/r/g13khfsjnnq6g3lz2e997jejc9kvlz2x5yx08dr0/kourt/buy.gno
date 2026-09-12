package kourt
import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)
const gnotDenom = "ugnot"
const burnSinkPath = "gno.land/r/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/kourt:burned"
func Buy(cur realm, slug string) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("kourtv2: a buy must be a direct user call")
	}
	buyer := prev.Address()
	c := mustCourt(slug)
	if buyer == cur.Address() {
		panic("kourtv2: the court's own address may not buy")
	}
	touch(c)
	sent := unsafe.OriginSend().AmountOf(gnotDenom)
	if sent <= 0 {
		panic("kourtv2: send GNOT to buy the coin")
	}
	delta, spent := c.crv.Minted(c.minted, sent)
	if delta <= 0 {
		panic("kourtv2: payment too small to mint a coin")
	}
	c.minted += delta
	recordPrice(c)
	c.coin.Mint(buyer, delta)
	reindexBurn(c, spent)
	accrueFranchise(c, buyer, spent)
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), chain.PackageAddress(burnSinkPath),
		chain.Coins{chain.NewCoin(gnotDenom, spent)})
	if r := sent - spent; r > 0 {
		b.SendCoins(cur.Address(), buyer, chain.Coins{chain.NewCoin(gnotDenom, r)})
	}
	return delta
}
func CurvePosition(slug string) int64 { return mustCourt(slug).minted }
func BurnSink() address { return chain.PackageAddress(burnSinkPath) }
func BurnedGNOT() int64 {
	b := banker.NewReadonlyBanker()
	return b.GetCoins(chain.PackageAddress(burnSinkPath)).AmountOf(gnotDenom)
}
func CoinBalanceOf(slug string, who address) int64 { return mustCourt(slug).coin.BalanceOf(who) }
