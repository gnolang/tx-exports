package game_vault

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/r/akkadia/beta/admin"
	gameworld "gno.land/r/akkadia/beta/game_world"
)

var vaultTest = &vaultTestHelper{
	Admin:    testutils.TestAddress("vaultAdmin"),
	Operator: testutils.TestAddress("vaultOperator"),
	Owner:    testutils.TestAddress("vaultOwner"),
	Player1:  testutils.TestAddress("vaultPlayer1"),
	Player2:  testutils.TestAddress("vaultPlayer2"),
}

type vaultTestHelper struct {
	Admin       address
	Operator    address
	Owner       address
	Player1     address
	Player2     address
	GameWorldID uint64
	setupDone   bool
}

func (h *vaultTestHelper) Setup(cur realm, t *testing.T) {
	t.Helper()
	resetGameVaultState()
	testing.SetOriginSend(chain.Coins{})
	if h.setupDone {
		return
	}

	originalAdmin := admin.GetAdmin()
	testing.SetOriginCaller(originalAdmin)
	testing.SetRealm(testing.NewUserRealm(originalAdmin))
	admin.TransferAdmin(cross(cur), h.Admin)

	testing.SetOriginCaller(h.Admin)
	testing.SetRealm(testing.NewUserRealm(h.Admin))
	admin.AcceptAdmin(cross(cur))
	admin.SetOperator(cross(cur), h.Operator)

	testing.SetOriginCaller(h.Operator)
	testing.SetRealm(testing.NewUserRealm(h.Operator))
	gameworld.SetGameTypePolicy(cross(cur), "vault_test", 0, gameworld.CreationModePublicCreator)

	testing.SetOriginCaller(h.Owner)
	testing.SetRealm(testing.NewUserRealm(h.Owner))
	h.GameWorldID = gameworld.CreateGameWorld(cross(cur), "vault_test")
	h.setupDone = true
}

func (h *vaultTestHelper) CreatePool(cur realm, key string) uint64 {
	testing.SetOriginCaller(h.Operator)
	testing.SetRealm(testing.NewUserRealm(h.Operator))
	testing.SetOriginSend(chain.Coins{})
	return CreateRewardPool(cross(cur), key, h.GameWorldID)
}

func (h *vaultTestHelper) CreateParticipationProcess(cur realm, key, poolKey string, fee int64) uint64 {
	testing.SetOriginCaller(h.Operator)
	testing.SetRealm(testing.NewUserRealm(h.Operator))
	testing.SetOriginSend(chain.Coins{})
	return CreateParticipationProcess(cross(cur), key, h.GameWorldID, poolKey, fee)
}

func (h *vaultTestHelper) CreateEntryProcess(cur realm, key string, fee int64) uint64 {
	testing.SetOriginCaller(h.Operator)
	testing.SetRealm(testing.NewUserRealm(h.Operator))
	testing.SetOriginSend(chain.Coins{})
	return CreateEntryProcess(cross(cur), key, h.GameWorldID, fee)
}

func (h *vaultTestHelper) DepositParticipation(cur realm, owner address, processID uint64, participationKey, paymentKey string, amount int64) uint64 {
	testing.SetOriginCaller(owner)
	testing.SetRealm(testing.NewUserRealm(owner))
	coins := chain.Coins{{"ugnot", amount}}
	testing.IssueCoins(chain.PackageAddress("gno.land/r/akkadia/beta/game_vault"), coins)
	testing.SetOriginSend(coins)
	return DepositParticipation(cross(cur), processID, participationKey, paymentKey)
}

func (h *vaultTestHelper) DepositEntry(cur realm, owner address, processID uint64, participationKey, entryKey string, amount int64) uint64 {
	testing.SetOriginCaller(owner)
	testing.SetRealm(testing.NewUserRealm(owner))
	coins := chain.Coins{{"ugnot", amount}}
	testing.IssueCoins(chain.PackageAddress("gno.land/r/akkadia/beta/game_vault"), coins)
	testing.SetOriginSend(coins)
	return DepositEntry(cross(cur), processID, participationKey, entryKey)
}

func (h *vaultTestHelper) DepositSystemFunding(cur realm, poolID uint64, key string, amount int64) uint64 {
	testing.SetOriginCaller(h.Operator)
	testing.SetRealm(testing.NewUserRealm(h.Operator))
	coins := chain.Coins{{"ugnot", amount}}
	testing.IssueCoins(chain.PackageAddress("gno.land/r/akkadia/beta/game_vault"), coins)
	testing.SetOriginSend(coins)
	return DepositSystemFunding(cross(cur), poolID, key)
}
