package kourtv3
import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"gno.land/p/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/grc20votes/v0"
)
const (
	burnBpsInit = int64(1000)
	minBurnBps = int64(500)
	maxBurnBps = int64(5000)
	bpsDenom = grc20votes.Bps
	coinUnit = int64(1_000_000)
	boughtEvent   = "Bought"
	redeemedEvent = "Redeemed"
)
var burnBps = burnBpsInit
var totalReserve int64
func BurnBps() int64 { return burnBps }
func SetBurnBps(cur realm, bps int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv3: only the global DAO admin sets the burn share")
	}
	mustSaneBurnBps(bps)
	old := burnBps
	burnBps = bps
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "set-burn-bps:"+strconv.FormatInt(old, 10)+"->"+strconv.FormatInt(bps, 10),
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}
func mustSaneBurnBps(bps int64) {
	if bps < minBurnBps || bps > maxBurnBps {
		panic("kourtv3: the burn share must be between " + strconv.FormatInt(minBurnBps, 10) +
			" and " + strconv.FormatInt(maxBurnBps, 10) + " bps")
	}
}
func splitPayment(c *Court, spent int64) (burned, reserved int64) {
	if c.oneWay {
		return spent, 0
	}
	reserved = mulDiv128(spent, bpsDenom-burnBps, bpsDenom)
	return spent - reserved, reserved
}
func redeemQuote(c *Court, amount int64) (payout, supply int64) {
	supply = c.coin.TotalSupply()
	if c.oneWay || amount <= 0 || c.reserve <= 0 || supply <= 0 || amount > supply {
		return 0, supply
	}
	return mulDiv128(c.reserve, amount, supply), supply
}
func mustReturnAMicroGNOT(c *Court, payout, supply int64) {
	if payout > 0 {
		return
	}
	least := supply / c.reserve
	if supply%c.reserve != 0 {
		least++
	}
	panic("kourtv3: too small to return a µGNOT — redeem at least " + ccAmt(least) + " CC")
}
func Redeem(cur realm, courtSlug string, amount int64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if amount <= 0 {
		panic("kourtv3: redeem amount must be positive")
	}
	if unsafe.OriginSend().AmountOf(gnotDenom) > 0 {
		panic("kourtv3: Redeem takes no GNOT")
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if c.oneWay {
		panic("kourtv3: this court's coin is one-way; nothing returns GNOT")
	}
	if who == c.escrow {
		panic("kourtv3: the court escrow cannot redeem")
	}
	touch(c)
	if c.reserve <= 0 {
		panic("kourtv3: this court holds no reserve")
	}
	mustSpendable(c, who, amount)
	payout, supply := redeemQuote(c, amount)
	mustReturnAMicroGNOT(c, payout, supply)
	c.coin.Burn(who, amount)
	if payout > c.reserve {
		panic("kourtv3: reserve accounting")
	}
	c.reserve -= payout
	totalReserve -= payout
	c.redeemedGNOT = mustAdd(c.redeemedGNOT, payout)
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), who, chain.Coins{chain.NewCoin(gnotDenom, payout)})
	chain.Emit(redeemedEvent,
		"court", c.id,
		"who", who.String(),
		"amount", strconv.FormatInt(amount, 10),
		"ugnot", strconv.FormatInt(payout, 10),
	)
	return payout
}
func ReserveGNOT(courtSlug string) int64 { return mustCourt(courtSlug).reserve }
func TotalReserveGNOT() int64 { return totalReserve }
func RedeemedGNOT(courtSlug string) int64 { return mustCourt(courtSlug).redeemedGNOT }
func RedeemValue(courtSlug string, amount int64) int64 {
	p, _ := redeemQuote(mustCourt(courtSlug), amount)
	return p
}
