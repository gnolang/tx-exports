package definition_test

import (
	"chain"
	"chain/runtime"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/akkadia/beta/admin"
	"gno.land/r/akkadia/beta/definition"
)

func TestExternalDefinitionsAndAdminRun(cur realm, t *testing.T) {
	caller := testutils.TestAddress("definitionExternal")
	testing.SetOriginCaller(admin.GetAdmin())
	testing.SetRealm(testing.NewUserRealm(admin.GetAdmin()))
	admin.TransferAdmin(cross(cur), caller)
	testing.SetOriginCaller(caller)
	testing.SetRealm(testing.NewUserRealm(caller))
	admin.AcceptAdmin(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(runtime.NewRealm(caller, "gno.land/e/"+caller.String()+"/run"))
	definition.SetDefinitions(cross(cur), "x", "name=before")
	value, found := definition.GetField("x", "name")["value"]
	uassert.True(t, found)
	uassert.Equal(t, "before", value)

	// A forged code path with the admin address still is not a user call/run.
	testing.SetRealm(runtime.NewRealm(caller, "gno.land/r/example/forged_definition_admin"))
	uassert.AbortsWithMessage(t, cur, "direct user call or run required", func() {
		definition.DeleteAll(cross(cur))
	})
	uassert.AbortsWithMessage(t, cur, "direct user call or run required", func() {
		definition.SetDefinitions(cross(cur), "x", "name=forged")
	})
	value, _ = definition.GetField("x", "name")["value"]
	uassert.Equal(t, "before", value)

	testing.SetRealm(runtime.NewRealm(caller, "gno.land/e/"+caller.String()+"/run"))
	definition.DeleteAll(cross(cur))
	uassert.Equal(t, len(definition.Get("x")), 0)
	definition.SetDefinitions(cross(cur), "x", "fresh=value")
	_, found = definition.GetField("x", "name")["value"]
	uassert.False(t, found)
	value, found = definition.GetField("x", "fresh")["value"]
	uassert.True(t, found)
	uassert.Equal(t, "value", value)
}
