package craft

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/akkadia/beta/admin"
	"gno.land/r/akkadia/beta/equipment"
	"gno.land/r/akkadia/beta/item"
)

var craftTest = struct {
	Admin, Owner, Other, FeeCollector, PkgAddr address
	SetupDone                                  bool
}{
	Admin:        testutils.TestAddress("craftAdmin"),
	Owner:        testutils.TestAddress("craftOwner"),
	Other:        testutils.TestAddress("craftOther"),
	FeeCollector: testutils.TestAddress("craftFeeCollector"),
	PkgAddr:      chain.PackageAddress("gno.land/r/akkadia/beta/craft"),
}

func setupCraftTest(cur realm, t *testing.T) {
	t.Helper()
	resetCraftState()
	testing.SetOriginSend(chain.Coins{})
	if !craftTest.SetupDone {
		originalAdmin := admin.GetAdmin()
		testing.SetOriginCaller(originalAdmin)
		testing.SetRealm(testing.NewUserRealm(originalAdmin))
		admin.TransferAdmin(cross(cur), craftTest.Admin)
		testing.SetOriginCaller(craftTest.Admin)
		testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
		admin.AcceptAdmin(cross(cur))
		admin.SetFeeCollector(cross(cur), craftTest.FeeCollector)
		craftTest.SetupDone = true
	}

	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	item.SetMinterRealm(cross(cur), "gno.land/r/akkadia/beta/craft")
	equipment.SetMinterRealm(cross(cur), "gno.land/r/akkadia/beta/craft")
}

func mintCraftItem(cur realm, tokenID string, amount int64) {
	testing.SetOriginCaller(craftTest.Admin)
	testing.SetRealm(testing.NewUserRealm(craftTest.Admin))
	item.SafeMint(cross(cur), craftTest.Owner, tokenID, amount)
}

func defaultCraftFeeCoins() chain.Coins {
	return chain.Coins{{"ugnot", defaultCraftFee}}
}

func payCraftFee(coins chain.Coins) {
	if len(coins) > 0 {
		testing.IssueCoins(craftTest.PkgAddr, coins)
	}
	testing.SetOriginSend(coins)
}

func ugnotBalanceForTest(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoins(addr).AmountOf("ugnot")
}
