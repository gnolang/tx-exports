package lotto

import (
	"chain"
	"testing"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/r/akkadia/beta/admin"
)

var (
	testAdmin    = testutils.TestAddress("lottoAdmin")
	testOperator = testutils.TestAddress("lottoOperator")
	testOwner    = testutils.TestAddress("lottoOwner")
	testOther    = testutils.TestAddress("lottoOther")
)

// Call with cross(cur); each test resets holdings and restores the operator.
func setupLotto(cur realm) {
	holdings = bptree.NewBPTree32()
	testing.SetOriginSend(chain.Coins{})
	originalAdmin := admin.GetAdmin()
	if originalAdmin != testAdmin {
		testing.SetOriginCaller(originalAdmin)
		testing.SetRealm(testing.NewUserRealm(originalAdmin))
		admin.TransferAdmin(cross(cur), testAdmin)
		testing.SetOriginCaller(testAdmin)
		testing.SetRealm(testing.NewUserRealm(testAdmin))
		admin.AcceptAdmin(cross(cur))
	}
	testing.SetOriginCaller(testAdmin)
	testing.SetRealm(testing.NewUserRealm(testAdmin))
	admin.SetOperator(cross(cur), testOperator)
}
