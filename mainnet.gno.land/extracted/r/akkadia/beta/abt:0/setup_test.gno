package abt

import (
	"chain"
	"testing"

	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/akkadia/beta/admin"
)

var abtTest = struct {
	Admin, Operator, Owner, Other address
}{
	Admin:    testutils.TestAddress("abtAdmin"),
	Operator: testutils.TestAddress("abtOperator"),
	Owner:    testutils.TestAddress("abtOwner"),
	Other:    testutils.TestAddress("abtOther"),
}

// Call with cross(cur) so token construction uses a live ABT realm.
func setupABT(cur realm, t *testing.T) {
	t.Helper()
	token, ledger = grc20.NewToken("Akkadia Beta Token", "abt", 6, 0, cur)
	frozen = true
	testing.SetOriginSend(chain.Coins{})
	originalAdmin := admin.GetAdmin()
	if originalAdmin != abtTest.Admin {
		testing.SetOriginCaller(originalAdmin)
		testing.SetRealm(testing.NewUserRealm(originalAdmin))
		admin.TransferAdmin(cross(cur), abtTest.Admin)
		testing.SetOriginCaller(abtTest.Admin)
		testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
		admin.AcceptAdmin(cross(cur))
	}
	testing.SetOriginCaller(abtTest.Admin)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	for _, operator := range admin.GetOperators() {
		admin.UnsetOperator(cross(cur), operator)
	}
	admin.SetOperator(cross(cur), abtTest.Operator)
}

func captureABTRealm(cur realm) realm { return cur }
