package agentpay

import (
	"chain"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/musd"
)

const callID = "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b"

func TestPayOnce(cur realm, t *testing.T) {
	payer := testutils.TestAddress("payer")
	agent := testutils.TestAddress("agent")
	self := chain.PackageAddress("gno.land/r/g12dcsmwccgdxasqde2eumua88tlrkw83kqf6tcz/agentpay")

	testing.SetRealm(testing.NewUserRealm(musd.Deployer))
	musd.Mint(cross(cur), payer, 10_000_000)
	testing.SetRealm(testing.NewUserRealm(payer))
	musd.Approve(cross(cur), self, 10_000_000)

	uassert.AbortsContains(t, cur, "BadCallId", func() { Pay(cross(cur), agent, 1, "abc") })
	uassert.AbortsContains(t, cur, "BadCallId", func() {
		Pay(cross(cur), agent, 1, "0000000000000000000000000000000000000000000000000000000000000000")
	})
	uassert.AbortsContains(t, cur, "ZeroAmount", func() { Pay(cross(cur), agent, 0, callID) })

	Pay(cross(cur), agent, 250_000, callID)
	uassert.Equal(t, int64(250_000), musd.BalanceOf(agent))
	uassert.Equal(t, int64(0), musd.BalanceOf(self)) // never custodial
	uassert.True(t, Used(payer, callID))
	uassert.AbortsContains(t, cur, "CallIdUsed", func() { Pay(cross(cur), agent, 250_000, callID) })
}
