package kourt2
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
		panic("kourtv2: only the global DAO admin prices court creation")
	}
	mustSanePrice(amount)
	courtCreationBurn = amount
}
func ugnotAmt(n int64) string { return ccAmt(n) }
func mustSanePrice(amount int64) {
	if amount < 0 {
		panic("kourtv2: a court-creation burn cannot be negative")
	}
}
func takeCourtCreationBurn(cur realm) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	price := courtCreationBurn
	if price <= 0 {
		return
	}
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("kourtv2: starting a court burns GNOT, so it must be a direct user call")
	}
	sent := unsafe.OriginSend().AmountOf(gnotDenom)
	if sent < price {
		panic("kourtv2: starting a court burns at least " + ugnotAmt(price) +
			" GNOT, you sent " + ugnotAmt(sent))
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), chain.PackageAddress(burnSinkPath),
		chain.Coins{chain.NewCoin(gnotDenom, sent)})
}
