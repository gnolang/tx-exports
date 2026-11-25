package b01

import (
	"chain"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

var (
	honest = address("g1honest00000000000000000000000000000000")
	hunter = address("g1hunter00000000000000000000000000000000")
)

func TestHonestDepositCannotClaim(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(honest))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 500)})
	Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, int64(500), BalanceOf(honest))
	uassert.False(t, Broken())
	testing.SetRealm(testing.NewUserRealm(honest))
	uassert.AbortsWithMessage(t, cur, "not broken for your address: the ledger credits you 500 ugnot and you paid 500", func() {
		Claim(cross(cur))
	})
}

func TestBreakThenClaimOnce(cur realm, t *testing.T) {
	// A user with a MsgRun script does the same as this: the leaked tree's
	// Set runs with the ground's authority.
	Ledger().Set(string(hunter), "anything")
	uassert.True(t, Broken())
	testing.SetRealm(testing.NewUserRealm(hunter))
	Claim(cross(cur))
	testing.SetRealm(testing.NewUserRealm(hunter))
	uassert.AbortsWithMessage(t, cur, "already on the hunters board", func() {
		Claim(cross(cur))
	})
	hs := Hunters()
	uassert.Equal(t, 1, len(hs))
	uassert.Equal(t, int64(1), hs[0].Credited) // a non-int64 value counts as 1
	page := Render("")
	uassert.True(t, strings.Contains(page, "🔴 Broken"), page)
	uassert.True(t, strings.Contains(page, "| 1 | `"+hunter.String()+"` |"), page)
	// Deposits still work for that address.
	testing.SetRealm(testing.NewUserRealm(hunter))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 5)})
	Deposit(cross(cur))
	testing.SetOriginSend(chain.Coins{})
	uassert.Equal(t, int64(6), BalanceOf(hunter))
}
