package abt_test

import (
	"chain"
	"chain/runtime"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/akkadia/beta/abt"
	"gno.land/r/akkadia/beta/admin"
)

func TestExternalWrapperLifecycle(cur realm, t *testing.T) {
	caller := testutils.TestAddress("abtExternalAdmin")
	owner := testutils.TestAddress("abtExternalOwner")
	other := testutils.TestAddress("abtExternalOther")
	testing.SetOriginCaller(admin.GetAdmin())
	testing.SetRealm(testing.NewUserRealm(admin.GetAdmin()))
	admin.TransferAdmin(cross(cur), caller)
	testing.SetOriginCaller(caller)
	testing.SetRealm(testing.NewUserRealm(caller))
	admin.AcceptAdmin(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	testing.SetRealm(runtime.NewRealm(caller, "gno.land/e/"+caller.String()+"/run"))
	abt.SetFrozen(cross(cur), true)
	supplyBefore := abt.TotalSupply()
	abt.Mint(cross(cur), owner, 20)
	uassert.Equal(t, "Akkadia Beta Token", abt.GetName())
	uassert.Equal(t, "abt", abt.GetSymbol())
	uassert.Equal(t, 6, abt.GetDecimals())
	uassert.Equal(t, supplyBefore+20, abt.TotalSupply())
	uassert.True(t, abt.IsFrozen())
	abt.SetFrozen(cross(cur), false)
	testing.SetOriginCaller(owner)
	testing.SetRealm(testing.NewUserRealm(owner))
	abt.Transfer(cross(cur), other, 2)
	abt.Approve(cross(cur), other, 5)
	testing.SetOriginCaller(other)
	testing.SetRealm(testing.NewUserRealm(other))
	abt.TransferFrom(cross(cur), owner, other, 3)
	uassert.Equal(t, int64(15), abt.BalanceOf(owner))
	uassert.Equal(t, int64(5), abt.BalanceOf(other))
	uassert.Equal(t, int64(2), abt.Allowance(owner, other))
	uassert.Equal(t, "15", abt.Render("balance/"+owner.String()))
	// A later failing transfer must preserve allowance even if its abort is caught.
	uassert.AbortsWithMessage(t, cur, "abt transfer failed: cannot send transfer to self", func() {
		abt.TransferFrom(cross(cur), owner, owner, 1)
	})
	uassert.Equal(t, int64(2), abt.Allowance(owner, other))
	testing.SetOriginCaller(caller)
	testing.SetRealm(testing.NewUserRealm(caller))
	abt.SetFrozen(cross(cur), true)
	testing.SetOriginCaller(other)
	testing.SetRealm(testing.NewUserRealm(other))
	uassert.AbortsWithMessage(t, cur, "abt is frozen", func() { abt.TransferFrom(cross(cur), owner, other, 2) })
	uassert.Equal(t, int64(2), abt.Allowance(owner, other))
	uassert.Equal(t, supplyBefore+20, abt.TotalSupply())
}
