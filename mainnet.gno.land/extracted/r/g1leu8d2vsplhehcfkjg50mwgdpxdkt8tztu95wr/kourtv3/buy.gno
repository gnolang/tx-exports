package kourtv3
import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
)
const gnotDenom = "ugnot"
const burnSinkPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/kourtv3:burned"
func Buy(cur realm, slug string, minUnits int64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("kourtv3: a buy must be a direct user call")
	}
	buyer := prev.Address()
	c := mustCourt(slug)
	if buyer == cur.Address() {
		panic("kourtv3: the court's own address may not buy")
	}
	touch(c)
	sent := unsafe.OriginSend().AmountOf(gnotDenom)
	if sent <= 0 {
		panic("kourtv3: send GNOT to buy the coin")
	}
	delta, spent := c.crv.Minted(c.minted, sent)
	if delta <= 0 {
		panic("kourtv3: payment too small to mint a coin")
	}
	if delta < minUnits {
		panic("kourtv3: this offering would mint fewer units than your floor — " +
			strconv.FormatInt(delta, 10) + " < " + strconv.FormatInt(minUnits, 10))
	}
	c.minted += delta
	recordPrice(c)
	c.coin.Mint(buyer, delta)
	burned, reserved := splitPayment(c, spent)
	c.reserve = mustAdd(c.reserve, reserved)
	c.paidIn = mustAdd(c.paidIn, spent)
	totalReserve = mustAdd(totalReserve, reserved)
	reindexBurn(c, burned)
	accrueFranchise(c, buyer, burned)
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), chain.PackageAddress(burnSinkPath),
		chain.Coins{chain.NewCoin(gnotDenom, burned)})
	if r := sent - spent; r > 0 {
		b.SendCoins(cur.Address(), buyer, chain.Coins{chain.NewCoin(gnotDenom, r)})
	}
	chain.Emit(boughtEvent,
		"court", c.id,
		"who", buyer.String(),
		"minted", strconv.FormatInt(delta, 10),
		"spent", strconv.FormatInt(spent, 10),
		"burned", strconv.FormatInt(burned, 10),
		"reserved", strconv.FormatInt(reserved, 10),
	)
	return delta
}
func CurvePosition(slug string) int64 { return mustCourt(slug).minted }
func BurnSink() address { return chain.PackageAddress(burnSinkPath) }
func BurnedGNOT() int64 {
	b := banker.NewReadonlyBanker()
	return b.GetCoin(chain.PackageAddress(burnSinkPath), gnotDenom)
}
func CoinBalanceOf(slug string, who address) int64 { return mustCourt(slug).coin.BalanceOf(who) }
