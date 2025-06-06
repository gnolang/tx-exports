package foo20

import (
	"std"
	"testing"

	"gno.land/p/demo/testutils"
	"gno.land/p/demo/uassert"
	pusers "gno.land/p/demo/users"
	"gno.land/r/demo/users"
)

func TestReadOnlyPublicMethods(t *testing.T) {
	var (
		admin = pusers.AddressOrName("g1manfred47kzduec920z88wfr64ylksmdcedlf5")
		alice = pusers.AddressOrName(testutils.TestAddress("alice"))
		bob   = pusers.AddressOrName(testutils.TestAddress("bob"))
	)

	type test struct {
		name    string
		balance uint64
		fn      func() uint64
	}

	// check balances #1.
	{
		tests := []test{
			{"TotalSupply", 10_000_000_000, func() uint64 { return TotalSupply() }},
			{"BalanceOf(admin)", 10_000_000_000, func() uint64 { return BalanceOf(admin) }},
			{"BalanceOf(alice)", 0, func() uint64 { return BalanceOf(alice) }},
			{"Allowance(admin, alice)", 0, func() uint64 { return Allowance(admin, alice) }},
			{"BalanceOf(bob)", 0, func() uint64 { return BalanceOf(bob) }},
		}
		for _, tc := range tests {
			got := tc.fn()
			uassert.Equal(t, got, tc.balance)
		}
	}

	// bob uses the faucet.
	std.TestSetOriginCaller(users.Resolve(bob))
	Faucet()

	// check balances #2.
	{
		tests := []test{
			{"TotalSupply", 10_010_000_000, func() uint64 { return TotalSupply() }},
			{"BalanceOf(admin)", 10_000_000_000, func() uint64 { return BalanceOf(admin) }},
			{"BalanceOf(alice)", 0, func() uint64 { return BalanceOf(alice) }},
			{"Allowance(admin, alice)", 0, func() uint64 { return Allowance(admin, alice) }},
			{"BalanceOf(bob)", 10_000_000, func() uint64 { return BalanceOf(bob) }},
		}
		for _, tc := range tests {
			got := tc.fn()
			uassert.Equal(t, got, tc.balance)
		}
	}
}

func TestErrConditions(t *testing.T) {
	var (
		admin = pusers.AddressOrName("g1manfred47kzduec920z88wfr64ylksmdcedlf5")
		alice = pusers.AddressOrName(testutils.TestAddress("alice"))
		empty = pusers.AddressOrName("")
	)

	type test struct {
		name string
		msg  string
		fn   func()
	}

	std.TestSetOriginCaller(users.Resolve(admin))
	{
		tests := []test{
			{"Transfer(admin, 1)", "cannot send transfer to self", func() { Transfer(admin, 1) }},
			{"Approve(empty, 1))", "invalid address", func() { Approve(empty, 1) }},
		}
		for _, tc := range tests {
			t.Run(tc.name, func(t *testing.T) {
				uassert.PanicsWithMessage(t, tc.msg, tc.fn)
			})
		}
	}
}
