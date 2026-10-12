package game_world

import (
	"chain"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestGameWorldInterrealmSecurity(cur realm, t *testing.T) {
	setupGameWorld(cross(cur), t)
	setPolicyForTest(cross(cur), testGameTypeJump, 0, CreationModePublicCreator)

	testing.SetOriginCaller(testCreator)
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/game_world_relay"))
	uassert.AbortsWithMessage(t, cur, "contract calls not allowed: function must be called directly by user", func() {
		CreateGameWorld(cross(cur), testGameTypeJump)
	})

	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/game_world_admin_relay"))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() {
		AddApprovedCreator(cross(cur), testGameTypeJump, testCreator)
	})
}
