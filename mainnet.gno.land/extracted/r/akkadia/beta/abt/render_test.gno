package abt

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestRender(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	Mint(cross(cur), abtTest.Owner, 123)
	for _, text := range []string{"Akkadia Beta Token", "$abt", "**Decimals**: 6", "**Total supply**: 123", "**Frozen**: true"} {
		uassert.True(t, strings.Contains(Render(""), text))
	}
	uassert.Equal(t, "123", Render("balance/"+abtTest.Owner.String()))
	uassert.Equal(t, "0", Render("balance/"+abtTest.Other.String()))
	for _, path := range []string{"unknown", "balance/", "balance/invalid", "balance/" + abtTest.Owner.String() + "/extra", "balance/<script>"} {
		uassert.Equal(t, "404", Render(path))
	}
	uassert.Equal(t, int64(123), TotalSupply())
	uassert.Equal(t, int64(123), BalanceOf(abtTest.Owner))
	uassert.Equal(t, int64(0), Allowance(abtTest.Owner, abtTest.Other))
	uassert.True(t, IsFrozen())
	SetFrozen(cross(cur), false)
	uassert.True(t, strings.Contains(Render(""), "**Frozen**: false"))
}
