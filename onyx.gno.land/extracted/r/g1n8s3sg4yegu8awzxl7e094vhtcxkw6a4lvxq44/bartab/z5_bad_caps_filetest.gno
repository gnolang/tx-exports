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
	at(t0)
	testing.SetRealm(testing.NewUserRealm(owner))
	send(10_000_000)
	id := bartab.OpenTab(cross(cur), agent, 1_000_000, 2_500_000, 3600, 0)
	at(t0 + 1)
	testing.SetRealm(testing.NewUserRealm(owner))
	bartab.SetCaps(cross(cur), id, 5_000_000, 1_000_000)
}

// Error:
// per-payment cap above daily cap
