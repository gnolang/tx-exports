package abt

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestTransferFailuresPreserveState(cur realm, t *testing.T) {
	cases := []struct {
		name     string
		caller   address
		call     func(_ int, rlm realm)
		panicMsg string
	}{
		{"transfer address", abtTest.Owner, func(_ int, rlm realm) { Transfer(cross(rlm), address("bad"), 1) }, "abt transfer failed: invalid address"},
		{"transfer negative", abtTest.Owner, func(_ int, rlm realm) { Transfer(cross(rlm), abtTest.Other, -1) }, "abt transfer failed: invalid amount"},
		{"transfer balance", abtTest.Owner, func(_ int, rlm realm) { Transfer(cross(rlm), abtTest.Other, 11) }, "abt transfer failed: insufficient balance"},
		{"transfer self", abtTest.Owner, func(_ int, rlm realm) { Transfer(cross(rlm), abtTest.Owner, 1) }, "abt transfer failed: cannot send transfer to self"},
		{"approve address", abtTest.Owner, func(_ int, rlm realm) { Approve(cross(rlm), address(""), 1) }, "abt approval failed: invalid address"},
		{"approve negative", abtTest.Owner, func(_ int, rlm realm) { Approve(cross(rlm), abtTest.Other, -1) }, "abt approval failed: invalid amount"},
		{"transferFrom owner", abtTest.Other, func(_ int, rlm realm) { TransferFrom(cross(rlm), address(""), abtTest.Admin, 1) }, "abt transfer failed: invalid address"},
		{"transferFrom recipient", abtTest.Other, func(_ int, rlm realm) { TransferFrom(cross(rlm), abtTest.Owner, address("bad"), 1) }, "abt transfer failed: invalid address"},
		{"transferFrom negative", abtTest.Other, func(_ int, rlm realm) { TransferFrom(cross(rlm), abtTest.Owner, abtTest.Admin, -1) }, "abt transfer failed: invalid amount"},
		{"transferFrom allowance", abtTest.Other, func(_ int, rlm realm) { TransferFrom(cross(rlm), abtTest.Owner, abtTest.Admin, 6) }, "abt transfer failed: insufficient allowance"},
		{"transferFrom balance", abtTest.Other, func(_ int, rlm realm) { TransferFrom(cross(rlm), abtTest.Owner, abtTest.Admin, 11) }, "abt transfer failed: insufficient balance"},
		{"transferFrom self", abtTest.Other, func(_ int, rlm realm) { TransferFrom(cross(rlm), abtTest.Owner, abtTest.Owner, 1) }, "abt transfer failed: cannot send transfer to self"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(cur realm, t *testing.T) {
			setupABT(cross(cur), t)
			testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
			Mint(cross(cur), abtTest.Owner, 10)
			SetFrozen(cross(cur), false)
			testing.SetOriginCaller(abtTest.Owner)
			testing.SetRealm(testing.NewUserRealm(abtTest.Owner))
			Approve(cross(cur), abtTest.Other, 5)
			testing.SetOriginCaller(tc.caller)
			testing.SetRealm(testing.NewUserRealm(tc.caller))
			uassert.AbortsWithMessage(t, cur, tc.panicMsg, func() { tc.call(0, cur) })
			uassert.Equal(t, int64(10), TotalSupply())
			uassert.Equal(t, int64(10), BalanceOf(abtTest.Owner))
			uassert.Equal(t, int64(0), BalanceOf(abtTest.Other))
			uassert.Equal(t, int64(0), BalanceOf(abtTest.Admin))
			uassert.Equal(t, int64(5), Allowance(abtTest.Owner, abtTest.Other))
		})
	}
}

func TestZeroTransfers(cur realm, t *testing.T) {
	setupABT(cross(cur), t)
	testing.SetRealm(testing.NewUserRealm(abtTest.Admin))
	SetFrozen(cross(cur), false)
	testing.SetOriginCaller(abtTest.Owner)
	testing.SetRealm(testing.NewUserRealm(abtTest.Owner))
	Transfer(cross(cur), abtTest.Other, 0)
	TransferFrom(cross(cur), abtTest.Other, abtTest.Admin, 0)
	uassert.Equal(t, int64(0), TotalSupply())
	uassert.Equal(t, int64(0), BalanceOf(abtTest.Other))
	uassert.Equal(t, int64(0), Allowance(abtTest.Other, abtTest.Owner))
}
