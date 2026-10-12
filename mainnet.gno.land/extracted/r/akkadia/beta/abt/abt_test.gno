package abt

import (
	"math"
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/r/akkadia/beta/admin"
)

func TestInitialState(t *testing.T) {
	uassert.Equal(t, "Akkadia Beta Token", GetName())
	uassert.Equal(t, "abt", GetSymbol())
	uassert.Equal(t, 6, GetDecimals())
	uassert.Equal(t, "gno.land/r/akkadia/beta/abt.abt.0000000", token.ID())
	uassert.True(t, IsFrozen())
	uassert.Equal(t, int64(0), TotalSupply())
	uassert.Equal(t, int64(0), BalanceOf(abtTest.Owner))
	uassert.Equal(t, int64(0), Allowance(abtTest.Owner, abtTest.Other))
}

func TestMintWhileFrozen(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	for _, caller := range []address{abtTest.Admin, abtTest.Operator} {
		testing.SetOriginCaller(caller)
		testing.SetRealm(testing.NewUserRealm(caller))
		Mint(cross(cur), abtTest.Owner, 100)
		Mint(cross(cur), abtTest.Other, 10)
	}
	uassert.True(t, IsFrozen())
	uassert.Equal(t, int64(220), TotalSupply())
	uassert.Equal(t, int64(200), BalanceOf(abtTest.Owner))
	uassert.Equal(t, int64(20), BalanceOf(abtTest.Other))
	uassert.Equal(t, int64(0), Allowance(abtTest.Owner, abtTest.Other))
}

func TestMintInvalidInput(cur realm, t *testing.T) {
	cases := []struct {
		name     string
		to       address
		amount   int64
		panicMsg string
	}{
		{"empty address", address(""), 1, "invalid abt recipient"},
		{"invalid address", address("invalid"), 1, "invalid abt recipient"},
		{"zero", abtTest.Owner, 0, "abt amount must be positive"},
		{"negative", abtTest.Owner, -1, "abt amount must be positive"},
		{"minimum int64", abtTest.Owner, math.MinInt64, "abt amount must be positive"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(cur realm, t *testing.T) {
			setupABT(cross(cur), t)
			testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
			Mint(cross(cur), abtTest.Owner, 7)
			uassert.AbortsWithMessage(t, cur, tc.panicMsg, func() {
				Mint(cross(cur), tc.to, tc.amount)
			})
			uassert.Equal(t, int64(7), TotalSupply())
			uassert.Equal(t, int64(7), BalanceOf(abtTest.Owner))
			uassert.Equal(t, int64(0), BalanceOf(abtTest.Other))
		})
	}
}

func TestMintOverflow(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	Mint(cross(cur), abtTest.Owner, math.MaxInt64)
	for _, to := range []address{abtTest.Owner, abtTest.Other} {
		uassert.AbortsWithMessage(t, cur, "abt mint failed: mint overflow", func() {
			Mint(cross(cur), to, 1)
		})
	}
	uassert.Equal(t, int64(math.MaxInt64), TotalSupply())
	uassert.Equal(t, int64(math.MaxInt64), BalanceOf(abtTest.Owner))
	uassert.Equal(t, int64(0), BalanceOf(abtTest.Other))
}

func TestFreezeLifecycle(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	Mint(cross(cur), abtTest.Owner, 100)
	SetFrozen(cross(cur), true)
	SetFrozen(cross(cur), false)
	SetFrozen(cross(cur), false)
	Mint(cross(cur), abtTest.Owner, 5)
	testing.SetOriginCaller(abtTest.Owner)
	testing.SetRealm(testing.NewUserRealm(abtTest.Owner))
	Transfer(cross(cur), abtTest.Other, 10)
	Approve(cross(cur), abtTest.Other, 40)
	testing.SetOriginCaller(abtTest.Other)
	testing.SetRealm(testing.NewUserRealm(abtTest.Other))
	TransferFrom(cross(cur), abtTest.Owner, abtTest.Admin, 15)
	uassert.Equal(t, int64(80), BalanceOf(abtTest.Owner))
	uassert.Equal(t, int64(10), BalanceOf(abtTest.Other))
	uassert.Equal(t, int64(15), BalanceOf(abtTest.Admin))
	uassert.Equal(t, int64(25), Allowance(abtTest.Owner, abtTest.Other))
	testing.SetOriginCaller(abtTest.Admin)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	SetFrozen(cross(cur), true)
	testing.SetOriginCaller(abtTest.Owner)
	testing.SetRealm(testing.NewUserRealm(abtTest.Owner))
	uassert.AbortsWithMessage(t, cur, "abt is frozen", func() { Approve(cross(cur), abtTest.Other, 0) })
	uassert.AbortsWithMessage(t, cur, "abt is frozen", func() { Transfer(cross(cur), abtTest.Other, 1) })
	testing.SetOriginCaller(abtTest.Other)
	testing.SetRealm(testing.NewUserRealm(abtTest.Other))
	uassert.AbortsWithMessage(t, cur, "abt is frozen", func() {
		TransferFrom(cross(cur), abtTest.Owner, abtTest.Admin, 25)
	})
	uassert.Equal(t, int64(25), Allowance(abtTest.Owner, abtTest.Other))
	uassert.Equal(t, int64(80), BalanceOf(abtTest.Owner))
	uassert.Equal(t, int64(105), TotalSupply())
	testing.SetOriginCaller(abtTest.Admin)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	SetFrozen(cross(cur), false)
	testing.SetOriginCaller(abtTest.Other)
	testing.SetRealm(testing.NewUserRealm(abtTest.Other))
	TransferFrom(cross(cur), abtTest.Owner, abtTest.Admin, 25)
	uassert.Equal(t, int64(0), Allowance(abtTest.Owner, abtTest.Other))
	uassert.Equal(t, int64(55), BalanceOf(abtTest.Owner))
	uassert.Equal(t, int64(40), BalanceOf(abtTest.Admin))
	uassert.Equal(t, int64(105), TotalSupply())
	testing.SetOriginCaller(abtTest.Owner)
	testing.SetRealm(testing.NewUserRealm(abtTest.Owner))
	Approve(cross(cur), abtTest.Other, 5)
	Approve(cross(cur), abtTest.Other, 7)
	uassert.Equal(t, int64(7), Allowance(abtTest.Owner, abtTest.Other))
	Approve(cross(cur), abtTest.Other, 0)
	uassert.Equal(t, int64(0), Allowance(abtTest.Owner, abtTest.Other))
}

func TestMintRoleChanges(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	admin.UnsetOperator(cross(cur), abtTest.Operator)
	testing.SetOriginCaller(abtTest.Operator)
	testing.SetRealm(testing.NewUserRealm(abtTest.Operator))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() { Mint(cross(cur), abtTest.Owner, 1) })
	testing.SetOriginCaller(abtTest.Admin)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	admin.TransferAdmin(cross(cur), abtTest.Other)
	testing.SetOriginCaller(abtTest.Other)
	testing.SetRealm(testing.NewUserRealm(abtTest.Other))
	admin.AcceptAdmin(cross(cur))
	Mint(cross(cur), abtTest.Owner, 3)
	SetFrozen(cross(cur), false)
	testing.SetOriginCaller(abtTest.Admin)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	uassert.AbortsWithMessage(t, cur, "admin or operator access required", func() { Mint(cross(cur), abtTest.Owner, 1) })
	uassert.AbortsWithMessage(t, cur, "admin access required", func() { SetFrozen(cross(cur), true) })
	uassert.Equal(t, int64(3), TotalSupply())
	uassert.False(t, IsFrozen())
}
