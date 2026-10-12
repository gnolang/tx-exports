package game_world

import (
	"chain"
	"chain/banker"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/akkadia/beta/admin"
)

var (
	testAdmin        = testutils.TestAddress("gwAdmin")
	testOperator     = testutils.TestAddress("gwOperator")
	testCreator      = testutils.TestAddress("gwCreator")
	testOtherCreator = testutils.TestAddress("gwOtherCreator")
	testRestricted   = testutils.TestAddress("gwRestricted")
	testNoPersonal   = testutils.TestAddress("gwNoPersonal")
	testFeeCollector = testutils.TestAddress("gwFeeCollector")
	testPkgAddr      = chain.PackageAddress("gno.land/r/akkadia/beta/game_world")
	setupDone        bool
)

const (
	testGameTypeDungeon = "instance_dungeon"
	testGameTypeJump    = "jump_map"
	testGameTypeRace    = "race_map"
	testGameTypeDrop    = "drop_map"
)

func setupGameWorld(cur realm, t *testing.T) {
	t.Helper()
	resetGameWorldState()
	testing.SetOriginSend(chain.Coins{})

	if setupDone {
		return
	}
	originalAdmin := admin.GetAdmin()
	testing.SetOriginCaller(originalAdmin)
	testing.SetRealm(testing.NewUserRealm(originalAdmin))
	admin.TransferAdmin(cross(cur), testAdmin)

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	admin.AcceptAdmin(cross(cur))
	admin.SetOperator(cross(cur), testOperator)
	admin.SetFeeCollector(cross(cur), testFeeCollector)
	setupDone = true
}

func setPolicyForTest(cur realm, gameType string, cost int64, mode CreationMode) {
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	SetGameTypePolicy(cross(cur), gameType, cost, mode)
}

func createGameWorldForTest(cur realm, creator address, gameType string, coins chain.Coins) uint64 {
	testing.SetOriginCaller(creator)
	testing.SetRealm(testing.NewUserRealm(creator))
	if len(coins) > 0 {
		testing.IssueCoins(testPkgAddr, coins)
	}
	testing.SetOriginSend(coins)
	return CreateGameWorld(cross(cur), gameType)
}

func ugnotBalanceForTest(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoins(addr).AmountOf("ugnot")
}
