package musd

import (
	"testing"
	"time"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

func TestFaucetCooldown(cur realm, t *testing.T) {
	alice := testutils.TestAddress("alice")
	testing.SetRealm(testing.NewUserRealm(alice))

	Faucet(cross(cur))
	uassert.Equal(t, FaucetAmount, BalanceOf(alice))
	uassert.Equal(t, time.Now().Unix()+int64(FaucetCooldown/time.Second), NextDrip(alice))

	uassert.AbortsContains(t, cur, "faucet: next drip", func() { Faucet(cross(cur)) })
	uassert.Equal(t, FaucetAmount, BalanceOf(alice))
}

func TestMintOwnerOnly(cur realm, t *testing.T) {
	bob := testutils.TestAddress("bob")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "", func() { Mint(cross(cur), bob, Unit) })
	uassert.Equal(t, int64(0), BalanceOf(bob))
}
