package dxv

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/r/nt/grc20reg/v0"
)

func TestFaucet(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetHeight(100)
	Faucet(cross(cur))
	uassert.Equal(t, int64(faucetDrop), BalanceOf(alice))
	uassert.AbortsContains(t, cur, "next claim at block", func() { Faucet(cross(cur)) })

	testing.SetHeight(100 + faucetEvery)
	Faucet(cross(cur))
	uassert.Equal(t, int64(2*faucetDrop), BalanceOf(alice))

	testing.SetRealm(testing.NewCodeRealm("gno.land/r/alice/bot"))
	uassert.AbortsContains(t, cur, "not a contract", func() { Faucet(cross(cur)) })
}

func TestRegistered(cur realm, t *testing.T) {
	uassert.True(t, grc20reg.Get(cur.PkgPath()+".DXV") != nil)
	uassert.Equal(t, "DXV", Token.GetSymbol())
	uassert.Equal(t, decimals, Token.GetDecimals())
}
