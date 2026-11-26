// PKGPATH: gno.land/r/test
package test

import (
	"chain"
	"chain/banker"
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/g1n8s3sg4yegu8awzxl7e094vhtcxkw6a4lvxq44/bartab"
)

var (
	owner   = testutils.TestAddress("owner")
	agent   = testutils.TestAddress("agent")
	brewery = testutils.TestAddress("brewery")
	bard    = testutils.TestAddress("bard")
	thief   = testutils.TestAddress("thief")
	realmA  = chain.PackageAddress("gno.land/r/g1n8s3sg4yegu8awzxl7e094vhtcxkw6a4lvxq44/bartab")
	t0      = int64(1_764_158_400) // 2025-11-26 12:00 UTC
)

func at(t int64) {
	ctx := testing.GetContext()
	ctx.Time = time.Unix(t, 0)
	ctx.Height = 100 + (t-t0)/5
	ctx.OriginSend = nil
	testing.SetContext(ctx)
}

func send(amount int64) {
	coins := chain.Coins{{"ugnot", amount}}
	testing.IssueCoins(realmA, coins) // the coins the user attached arrive at the realm
	testing.SetOriginSend(coins)
}

func bal(a address) int64 { return banker.NewReadonlyBanker().GetCoin(a, "ugnot") }

func main(cur realm) {
	// owner opens a 10 GNOT tab: 1 GNOT per payment, 2.5 GNOT a day, 1 h payee hold
	at(t0)
	testing.SetRealm(testing.NewUserRealm(owner))
	send(10_000_000)
	id := bartab.OpenTab(cross(cur), agent, 1_000_000, 2_500_000, 3600, 0)
	println("tab", id, "balance", bartab.Balance(id))

	at(t0)
	testing.SetRealm(testing.NewUserRealm(owner))
	bartab.SetPayee(cross(cur), id, "brewery", brewery)
	at(t0)
	testing.SetRealm(testing.NewUserRealm(owner))
	bartab.SetPayee(cross(cur), id, "bard", bard)

	// within the payee hold: held
	at(t0+60)
	testing.SetRealm(testing.NewUserRealm(agent))
	println("1 new payee:", bartab.Order(cross(cur), id, brewery, 400_000, "first keg", "k1"))

	// after the hold: paid
	at(t0+3601)
	testing.SetRealm(testing.NewUserRealm(agent))
	println("2 after hold:", bartab.Order(cross(cur), id, brewery, 400_000, "keg", "k2"))
	// retry of the same order: same answer, not paid twice
	at(t0+3602)
	testing.SetRealm(testing.NewUserRealm(agent))
	println("3 retry k2:", bartab.Order(cross(cur), id, brewery, 400_000, "keg", "k2"))
	println("  brewery has", bal(brewery))

	// unknown payee: refused, but recorded
	at(t0+3603)
	testing.SetRealm(testing.NewUserRealm(agent))
	println("4 stranger:", bartab.Order(cross(cur), id, thief, 10_000, "tip?", "k3"))

	// over the per-payment cap: held
	at(t0+3604)
	testing.SetRealm(testing.NewUserRealm(agent))
	println("5 big order:", bartab.Order(cross(cur), id, bard, 1_500_000, "ballad", "k4"))

	// payee address swapped (invoice-fraud move): new address is on hold again
	at(t0+3605)
	testing.SetRealm(testing.NewUserRealm(owner))
	bartab.SetPayee(cross(cur), id, "bard", thief)
	at(t0+3606)
	testing.SetRealm(testing.NewUserRealm(agent))
	println("6 swapped bard:", bartab.Order(cross(cur), id, thief, 100_000, "ballad deposit", "k5"))

	// owner approves hold 2 (the 1.5 GNOT ballad to the OLD bard address): refused, the address is no longer a payee
	at(t0+3607)
	testing.SetRealm(testing.NewUserRealm(owner))
	println("7 approve hold 2:", bartab.Approve(cross(cur), id, 2))
	// owner approves hold 1 (first keg): paid, the soft limit is lifted
	at(t0+3608)
	testing.SetRealm(testing.NewUserRealm(owner))
	println("8 approve hold 1:", bartab.Approve(cross(cur), id, 1))
	println("  brewery has", bal(brewery))

	// daily cap: 0.8 spent; 1.0 + 0.8 = 1.8 ok; then 1.0 more = 2.8 > 2.5: held
	at(t0+3609)
	testing.SetRealm(testing.NewUserRealm(agent))
	println("9 keg:", bartab.Order(cross(cur), id, brewery, 1_000_000, "keg", "k6"))
	at(t0+3610)
	testing.SetRealm(testing.NewUserRealm(agent))
	println("10 keg over day cap:", bartab.Order(cross(cur), id, brewery, 1_000_000, "keg", "k7"))

	// next UTC day: the daily counter resets
	at(t0+43_200+1)
	testing.SetRealm(testing.NewUserRealm(agent))
	println("12 next day:", bartab.Order(cross(cur), id, brewery, 1_000_000, "keg", "k8"))

	// kill switch: freeze cancels pending holds, next order refused
	at(t0+43_200+2)
	testing.SetRealm(testing.NewUserRealm(owner))
	bartab.Freeze(cross(cur), id)
	at(t0+43_200+3)
	testing.SetRealm(testing.NewUserRealm(agent))
	println("13 frozen:", bartab.Order(cross(cur), id, brewery, 1, "", "k9"))

	// close: refund the rest to the owner
	at(t0+43_200+4)
	testing.SetRealm(testing.NewUserRealm(owner))
	before := bal(owner)
	bartab.CloseTab(cross(cur), id)
	println("14 refund:", bal(owner)-before, "tab balance", bartab.Balance(id), "realm holds", bal(realmA))
	println("brewery total", bal(brewery), "thief total", bal(thief), "bard total", bal(bard))
	println("last:", bartab.LastDecision(id))
}

// Output:
// tab 1 balance 10000000
// 1 new payee: hold:1:payee-hold
// 2 after hold: allow
// 3 retry k2: allow
//   brewery has 400000
// 4 stranger: deny:unknown-payee
// 5 big order: hold:2:over-per-payment
// 6 swapped bard: hold:3:payee-hold
// 7 approve hold 2: deny:unknown-payee
// 8 approve hold 1: allow
//   brewery has 800000
// 9 keg: allow
// 10 keg over day cap: hold:4:over-daily-cap
// 12 next day: allow
// 13 frozen: deny:frozen
// 14 refund: 7200000 tab balance 0 realm holds 0
// brewery total 2800000 thief total 0 bard total 0
// last: close closed 7200000
