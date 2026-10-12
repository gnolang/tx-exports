package game_world

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestGameTypePoliciesStartEmptyAndAdminRegistersOpaqueKey(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	uassert.False(t, HasGameTypePolicy(testGameTypeDungeon))
	uassert.False(t, HasGameTypePolicy(testGameTypeJump))

	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	SetGameTypePolicy(cross(cur), "custom_type_alpha", 17, CreationModeApprovedCreator)

	uassert.True(t, HasGameTypePolicy("custom_type_alpha"))
	policy := GetGameTypePolicy("custom_type_alpha")
	uassert.Equal(t, int64(17), policy.CreationCost)
	uassert.Equal(t, int(CreationModeApprovedCreator), int(policy.CreationMode))
}

func TestApprovedCreatorIsManagedPerOpaqueKey(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModeApprovedCreator)
	setPolicyForTest(cross(cur), testGameTypeRace, 0, CreationModeApprovedCreator)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))

	AddApprovedCreator(cross(cur), testGameTypeJump, testCreator)
	uassert.True(t, IsApprovedCreator(testGameTypeJump, testCreator))
	uassert.False(t, IsApprovedCreator(testGameTypeRace, testCreator))

	RemoveApprovedCreator(cross(cur), testGameTypeJump, testCreator)
	uassert.False(t, IsApprovedCreator(testGameTypeJump, testCreator))
}

func TestAddAndRemoveApprovedCreator(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModeApprovedCreator)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))

	AddApprovedCreator(cross(cur), testGameTypeJump, testCreator)
	uassert.True(t, IsApprovedCreator(testGameTypeJump, testCreator))

	RemoveApprovedCreator(cross(cur), testGameTypeJump, testCreator)
	uassert.False(t, IsApprovedCreator(testGameTypeJump, testCreator))
}

func TestSetApprovedCreatorsBulk(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModeApprovedCreator)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	creatorsCSV := testCreator.String() + "," + testOtherCreator.String()

	SetApprovedCreators(cross(cur), testGameTypeJump, creatorsCSV, true)
	uassert.True(t, IsApprovedCreator(testGameTypeJump, testCreator))
	uassert.True(t, IsApprovedCreator(testGameTypeJump, testOtherCreator))

	SetApprovedCreators(cross(cur), testGameTypeJump, creatorsCSV, false)
	uassert.False(t, IsApprovedCreator(testGameTypeJump, testCreator))
	uassert.False(t, IsApprovedCreator(testGameTypeJump, testOtherCreator))
}

func TestSetApprovedCreatorsRejectsInvalidAndEmptyCSV(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModeApprovedCreator)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))

	uassert.AbortsWithMessage(t, cur, "invalid creator address", func() {
		SetApprovedCreators(cross(cur), testGameTypeJump, testCreator.String()+",invalid", true)
	})

	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModeApprovedCreator)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	uassert.AbortsWithMessage(t, cur, "creator list must not be empty", func() {
		SetApprovedCreators(cross(cur), testGameTypeJump, "", true)
	})
}

func TestSetApprovedCreatorsAllowsDuplicateAddresses(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModeApprovedCreator)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	creatorsCSV := testCreator.String() + "," + testCreator.String()

	SetApprovedCreators(cross(cur), testGameTypeJump, creatorsCSV, true)
	uassert.True(t, IsApprovedCreator(testGameTypeJump, testCreator))
	uassert.Equal(t, 1, GetApprovedCreatorCount(testGameTypeJump))

	SetApprovedCreators(cross(cur), testGameTypeJump, creatorsCSV, false)
	uassert.False(t, IsApprovedCreator(testGameTypeJump, testCreator))
}

func TestSetApprovedCreatorsRejectsEmptyEntryAndOversizedBatch(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModeApprovedCreator)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))

	uassert.AbortsWithMessage(t, cur, "invalid creator address", func() {
		SetApprovedCreators(cross(cur), testGameTypeJump, testCreator.String()+",", true)
	})

	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModeApprovedCreator)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	creatorsCSV := testCreator.String()
	for i := 1; i < 101; i++ {
		creatorsCSV += "," + testCreator.String()
	}
	uassert.AbortsWithMessage(t, cur, "creator list exceeds limit", func() {
		SetApprovedCreators(cross(cur), testGameTypeJump, creatorsCSV, true)
	})
}

func TestListApprovedCreatorsSupportsManagementProjection(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeDrop, 0, CreationModeApprovedCreator)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	AddApprovedCreator(cross(cur), testGameTypeDrop, testCreator)
	AddApprovedCreator(cross(cur), testGameTypeDrop, testOtherCreator)

	uassert.Equal(t, 2, GetApprovedCreatorCount(testGameTypeDrop))
	listed := ListApprovedCreators(testGameTypeDrop, 0, 100)
	uassert.Equal(t, 2, len(listed))
	uassert.True(t, containsApprovedCreator(listed, testCreator))
	uassert.True(t, containsApprovedCreator(listed, testOtherCreator))
}

func containsApprovedCreator(creators []address, target address) bool {
	for _, creator := range creators {
		if creator == target {
			return true
		}
	}
	return false
}

func TestSetGameTypePolicyRejectsUnauthorizedCaller(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	testing.SetOriginCaller(testCreator)
	testing.SetRealm(testing.NewUserRealm(testCreator))

	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		SetGameTypePolicy(cross(cur), testGameTypeJump, 10, CreationModeApprovedCreator)
	})
}

func TestSetGameTypePolicyValidatesOpaqueKeyAndPolicy(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))

	uassert.AbortsWithMessage(t, cur, "game type key length must be between 1 and 64", func() {
		SetGameTypePolicy(cross(cur), "", 0, CreationModeOperatorOnly)
	})
	uassert.AbortsWithMessage(t, cur, "game type key length must be between 1 and 64", func() {
		SetGameTypePolicy(cross(cur), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 0, CreationModeOperatorOnly)
	})
	uassert.AbortsWithMessage(t, cur, "invalid game type key", func() {
		SetGameTypePolicy(cross(cur), "Jump Map", 0, CreationModeOperatorOnly)
	})
	uassert.AbortsWithMessage(t, cur, "creation cost must not be negative", func() {
		SetGameTypePolicy(cross(cur), testGameTypeJump, -1, CreationModeOperatorOnly)
	})
	uassert.AbortsWithMessage(t, cur, "invalid creation mode", func() {
		SetGameTypePolicy(cross(cur), testGameTypeJump, 0, CreationModeInvalid)
	})
}

func TestUnregisteredGameTypeIsRejected(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	testing.SetOriginCaller(testCreator)
	testing.SetRealm(testing.NewUserRealm(testCreator))

	uassert.AbortsWithMessage(t, cur, "game type policy not found: unknown_type", func() {
		CreateGameWorld(cross(cur), "unknown_type")
	})

	testing.SetOriginCaller(testOperator)
	testing.SetRealm(testing.NewUserRealm(testOperator))
	uassert.AbortsWithMessage(t, cur, "game type policy not found: unknown_type", func() {
		AddApprovedCreator(cross(cur), "unknown_type", testCreator)
	})
}
