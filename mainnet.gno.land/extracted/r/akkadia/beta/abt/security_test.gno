package abt

import (
	"chain"
	"chain/runtime"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/r/akkadia/beta/admin"
)

func TestUnauthorizedMintAndFreeze(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	testing.SetOriginCaller(abtTest.Owner)
	testing.SetRealm(testing.NewUserRealm(abtTest.Owner))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() { Mint(cross(cur), abtTest.Owner, 1) })
	for _, caller := range []address{abtTest.Owner, abtTest.Operator} {
		testing.SetOriginCaller(caller)
		testing.SetRealm(testing.NewUserRealm(caller))
		for _, value := range []bool{true, false} {
			uassert.AbortsWithMessage(t, cur, "admin access required", func() { SetFrozen(cross(cur), value) })
		}
	}
	for _, signer := range []address{abtTest.Admin, abtTest.Operator} {
		testing.SetOriginCaller(signer)
		testing.SetRealm(testing.NewCodeRealm("gno.land/r/example/abt_relay"))
		uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() { Mint(cross(cur), abtTest.Owner, 1) })
		uassert.AbortsWithMessage(t, cur, "admin access required", func() { SetFrozen(cross(cur), false) })
	}
	uassert.True(t, IsFrozen())
	uassert.Equal(t, int64(0), TotalSupply())
	uassert.Equal(t, int64(0), BalanceOf(abtTest.Owner))
}

func TestFrozenRejectsAllCallers(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	for _, caller := range []address{abtTest.Admin, abtTest.Operator, abtTest.Owner} {
		testing.SetOriginCaller(abtTest.Admin)
		testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
		Mint(cross(cur), caller, 10)
		testing.SetOriginCaller(caller)
		testing.SetRealm(testing.NewUserRealm(caller))
		uassert.AbortsWithMessage(t, cur, "abt is frozen", func() { Transfer(cross(cur), abtTest.Other, 1) })
		uassert.AbortsWithMessage(t, cur, "abt is frozen", func() { Approve(cross(cur), abtTest.Other, 1) })
		uassert.AbortsWithMessage(t, cur, "abt is frozen", func() { Approve(cross(cur), abtTest.Other, 0) })
		uassert.AbortsWithMessage(t, cur, "abt is frozen", func() { TransferFrom(cross(cur), caller, abtTest.Other, 1) })
		uassert.Equal(t, int64(10), BalanceOf(caller))
		uassert.Equal(t, int64(0), Allowance(caller, abtTest.Other))
	}
	uassert.Equal(t, int64(30), TotalSupply())
	uassert.Equal(t, int64(0), BalanceOf(abtTest.Other))
}

func TestAttachedCoinsRejected(cur realm, t *testing.T) {
	cases := []struct {
		name string
		call func(_ int, rlm realm)
	}{
		{"mint", func(_ int, rlm realm) { Mint(cross(rlm), abtTest.Owner, 1) }},
		{"freeze", func(_ int, rlm realm) { SetFrozen(cross(rlm), true) }},
		{"freeze no-op", func(_ int, rlm realm) { SetFrozen(cross(rlm), false) }},
		{"transfer", func(_ int, rlm realm) { Transfer(cross(rlm), abtTest.Other, 1) }},
		{"approve", func(_ int, rlm realm) { Approve(cross(rlm), abtTest.Other, 1) }},
		{"transferFrom", func(_ int, rlm realm) { TransferFrom(cross(rlm), abtTest.Owner, abtTest.Other, 1) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(cur realm, t *testing.T) {
			setupABT(cross(cur), t)
			testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
			Mint(cross(cur), abtTest.Admin, 10)
			SetFrozen(cross(cur), false)
			for _, caller := range []runtime.Realm{
				testing.NewUserRealm(abtTest.Admin),
				runtime.NewRealm(abtTest.Admin, "gno.land/e/"+abtTest.Admin.String()+"/run"),
			} {
				testing.SetRealm(caller)
				testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
				uassert.AbortsWithMessage(t, cur, "attached coins not allowed", func() { tc.call(0, cur) })
				uassert.False(t, IsFrozen())
				uassert.Equal(t, int64(10), TotalSupply())
				uassert.Equal(t, int64(10), BalanceOf(abtTest.Admin))
				uassert.Equal(t, int64(0), BalanceOf(abtTest.Other))
				uassert.Equal(t, int64(0), Allowance(abtTest.Admin, abtTest.Other))
			}
		})
	}
}

func TestRelayUsesOwnBalanceAndAllowance(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	relay := testing.NewCodeRealm("gno.land/r/example/abt_relay")
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	Mint(cross(cur), abtTest.Owner, 100)
	Mint(cross(cur), relay.Address(), 20)
	SetFrozen(cross(cur), false)
	testing.SetOriginCaller(abtTest.Owner)
	testing.SetRealm(testing.NewUserRealm(abtTest.Owner))
	Approve(cross(cur), relay.Address(), 7)
	Approve(cross(cur), abtTest.Owner, 30)
	// These coins belong to the relay's origin call, not to ABT.
	testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
	testing.SetRealm(relay)
	Transfer(cross(cur), abtTest.Other, 5)
	Approve(cross(cur), abtTest.Other, 3)
	TransferFrom(cross(cur), abtTest.Owner, abtTest.Other, 7)
	uassert.AbortsWithMessage(t, cur, "abt transfer failed: insufficient allowance", func() {
		TransferFrom(cross(cur), abtTest.Owner, abtTest.Other, 1)
	})
	uassert.Equal(t, int64(93), BalanceOf(abtTest.Owner))
	uassert.Equal(t, int64(15), BalanceOf(relay.Address()))
	uassert.Equal(t, int64(12), BalanceOf(abtTest.Other))
	uassert.Equal(t, int64(3), Allowance(relay.Address(), abtTest.Other))
	uassert.Equal(t, int64(0), Allowance(abtTest.Owner, abtTest.Other))
	uassert.Equal(t, int64(0), Allowance(abtTest.Owner, relay.Address()))
	uassert.Equal(t, int64(30), Allowance(abtTest.Owner, abtTest.Owner))
	uassert.Equal(t, int64(120), TotalSupply())
	testing.SetOriginSend(chain.Coins{})
	testing.SetOriginCaller(abtTest.Admin)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	SetFrozen(cross(cur), true)
	testing.SetRealm(relay)
	uassert.AbortsWithMessage(t, cur, "abt is frozen", func() { Transfer(cross(cur), abtTest.Other, 1) })
	uassert.AbortsWithMessage(t, cur, "abt is frozen", func() { Approve(cross(cur), abtTest.Other, 0) })
	uassert.AbortsWithMessage(t, cur, "abt is frozen", func() { TransferFrom(cross(cur), abtTest.Owner, abtTest.Other, 1) })
}

func TestOperatorRealmCanMintWithOwnAuthority(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	relay := testing.NewCodeRealm("gno.land/r/example/abt_operator")
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	admin.SetOperator(cross(cur), relay.Address())
	testing.SetOriginCaller(abtTest.Owner)
	testing.SetOriginSend(chain.Coins{{"ugnot", 1}})
	testing.SetRealm(relay)
	Mint(cross(cur), abtTest.Owner, 2)
	uassert.AbortsWithMessage(t, cur, "admin access required", func() { SetFrozen(cross(cur), false) })
	uassert.Equal(t, int64(2), TotalSupply())
	uassert.True(t, IsFrozen())
}

func TestSpoofedRealmRejected(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	stale := captureABTRealm(cross(cur))
	uassert.PanicsWithMessage(t, cur, "spoofed realm", func() { assertCanTransfer(0, stale) })
	uassert.True(t, IsFrozen())
	uassert.Equal(t, int64(0), TotalSupply())
}
