package game_world

import (
	"chain"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestCreateGameWorldUsesCallerAsOwnerAndChargesExactCost(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 25, CreationModePublicCreator)
	collectorBefore := ugnotBalanceForTest(testFeeCollector)

	id := createGameWorldForTest(cross(cur), testCreator, testGameTypeJump, chain.Coins{{"ugnot", 25}})

	uassert.Equal(t, uint64(1), id)
	uassert.Equal(t, uint64(1), GetLatestGameWorldID())
	world := GetGameWorld(id)
	uassert.Equal(t, testCreator.String(), world.Owner.String())
	uassert.Equal(t, testGameTypeJump, world.GameType)
	uassert.Equal(t, int64(25), ugnotBalanceForTest(testFeeCollector)-collectorBefore)
	uassert.Equal(t, int64(0), ugnotBalanceForTest(testPkgAddr))
}

func TestCreateGameWorldDoesNotRequirePersonalWorld(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModePublicCreator)

	uassert.True(t, HasGameWorld(createGameWorldForTest(cross(cur), testNoPersonal, testGameTypeJump, chain.Coins{})))
}

func TestOperatorOnlyCreationAllowsOperator(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModeOperatorOnly)

	uassert.True(t, HasGameWorld(createGameWorldForTest(cross(cur), testOperator, testGameTypeJump, chain.Coins{})))
}

func TestApprovedCreatorFlowAndRevocation(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeRace, 0, CreationModeApprovedCreator)

	uassert.AbortsWithMessage(t, cur, "creator is not approved for game type", func() {
		createGameWorldForTest(cross(cur), testCreator, testGameTypeRace, chain.Coins{})
	})

	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	AddApprovedCreator(cross(cur), testGameTypeRace, testCreator)
	id := createGameWorldForTest(cross(cur), testCreator, testGameTypeRace, chain.Coins{})
	uassert.True(t, HasGameWorld(id))

	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	RemoveApprovedCreator(cross(cur), testGameTypeRace, testCreator)
	uassert.True(t, HasGameWorld(id))
	uassert.AbortsWithMessage(t, cur, "creator is not approved for game type", func() {
		createGameWorldForTest(cross(cur), testCreator, testGameTypeRace, chain.Coins{})
	})
}

func TestCreateGameWorldRejectsInexactPayment(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeDrop, 25, CreationModePublicCreator)

	uassert.AbortsWithMessage(t, cur, "exact payment required: expected 25ugnot, got 24ugnot", func() {
		createGameWorldForTest(cross(cur), testCreator, testGameTypeDrop, chain.Coins{{"ugnot", 24}})
	})
	uassert.Equal(t, uint64(0), GetLatestGameWorldID())

	uassert.AbortsWithMessage(t, cur, "exact payment required: expected 25ugnot, got 25ugnot,1foo", func() {
		createGameWorldForTest(cross(cur), testCreator, testGameTypeDrop, chain.Coins{{"ugnot", 25}, {"foo", 1}})
	})
	uassert.Equal(t, uint64(0), GetLatestGameWorldID())
}

func TestApprovedCreatorModeDoesNotImplicitlyApproveOperator(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeRace, 0, CreationModeApprovedCreator)

	uassert.AbortsWithMessage(t, cur, "creator is not approved for game type", func() {
		createGameWorldForTest(cross(cur), testOperator, testGameTypeRace, chain.Coins{})
	})
}

func TestCreateGameWorldRejectsIDOverflow(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModePublicCreator)
	latestGameWorldID = uint64(18446744073709551615)

	uassert.AbortsWithMessage(t, cur, "game world id exhausted", func() {
		createGameWorldForTest(cross(cur), testCreator, testGameTypeJump, chain.Coins{})
	})
}

func TestListLatestGameWorldsByOwner(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModePublicCreator)
	firstID := createGameWorldForTest(cross(cur), testCreator, testGameTypeJump, chain.Coins{})
	createGameWorldForTest(cross(cur), testOtherCreator, testGameTypeJump, chain.Coins{})
	for i := 1; i <= gameWorldListLimit; i++ {
		createGameWorldForTest(cross(cur), testCreator, testGameTypeJump, chain.Coins{})
	}

	worlds := ListLatestGameWorldsByOwner(testCreator)
	uassert.Equal(t, gameWorldListLimit, len(worlds))
	uassert.Equal(t, firstID+2, worlds[0].ID)
	uassert.Equal(t, firstID+uint64(gameWorldListLimit+1), worlds[len(worlds)-1].ID)
	uassert.Equal(t, testGameTypeJump, worlds[0].GameType)
	uassert.Equal(t, 0, len(ListLatestGameWorldsByOwner(address("g1missing"))))
}
