package kourtv3
import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)
const courtCreationBurnInit = int64(0)
var courtCreationBurn = courtCreationBurnInit
func CourtCreationBurn() int64 { return courtCreationBurn }
func SetCourtCreationBurn(cur realm, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv3: only the global DAO admin prices court creation")
	}
	mustSanePrice(amount)
	courtCreationBurn = amount
}
func ugnotAmt(n int64) string { return ccAmt(n) }
func mustSanePrice(amount int64) {
	if amount < 0 {
		panic("kourtv3: a court-creation burn cannot be negative")
	}
}
func takeCourtCreationBurn(cur realm) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	price := courtCreationBurn
	prev := cur.Previous()
	if price <= 0 {
		if prev.IsUserCall() && unsafe.OriginSend().AmountOf(gnotDenom) > 0 {
			panic("kourtv3: court creation is free right now; send no GNOT")
		}
		return
	}
	if !prev.IsUserCall() {
		panic("kourtv3: starting a court burns GNOT, so it must be a direct user call")
	}
	sent := unsafe.OriginSend().AmountOf(gnotDenom)
	if sent < price {
		panic("kourtv3: starting a court burns at least " + ugnotAmt(price) +
			" GNOT, you sent " + ugnotAmt(sent))
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), chain.PackageAddress(burnSinkPath),
		chain.Coins{chain.NewCoin(gnotDenom, sent)})
}
