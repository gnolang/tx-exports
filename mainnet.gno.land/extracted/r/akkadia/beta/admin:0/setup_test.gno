package admin

import (
	"testing"

	"chain"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/testutils/v0"
)

var (
	testAdmin        = testutils.TestAddress("testAdmin")
	testOperator     = testutils.TestAddress("testOperator")
	testUser         = testutils.TestAddress("testUser")
	testUser2        = testutils.TestAddress("testUser2")
	unauthorizedUser = testutils.TestAddress("unauthorizedUser")
	testProtocol     = testutils.TestAddress("testProtocol")
)

// setupCommonAdminTests initializes common admin test environment.
func setupCommonAdminTests(cur realm, t *testing.T) {
	t.Helper()
	admin = testAdmin
	pendingAdmin = address("")
	operatorAddrs = bptree.NewBPTree32()
	operatorAddrs.Set(testAdmin.String(), true)
	feeCollectorAddr = adminRealmAddr()
	protocolAddr = testAdmin
	faucetTargetAmount = 0
	explorerURL = "https://app.beta.akkadia.land"
}

func adminRealmAddr() address {
	return chain.PackageAddress("gno.land/r/akkadia/beta/admin")
}

func containsOperator(operators []address, addr address) bool {
	for _, operator := range operators {
		if operator == addr {
			return true
		}
	}
	return false
}
