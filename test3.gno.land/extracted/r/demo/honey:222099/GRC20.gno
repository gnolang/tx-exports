package HONEY

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	HONEY  *grc20.AdminToken
	admin std.Address = "g1lk45335udge6nefk733e852rmexrc94m52tdt9"
)

func init() {
	HONEY = grc20.NewAdminToken("HONEYToken", "HONEY", 6)
	HONEY.Mint(admin, 1000000000) // @administrator
}

// method proxies as public functions.
//

// getters.

func TotalSupply() uint64 {
	return HONEY.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := HONEY.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := HONEY.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	HONEY.Transfer(caller, to.Resolve(), amount)
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	HONEY.Approve(caller, spender.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	HONEY.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	HONEY.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	HONEY.Burn(address.Resolve(), amount)
}

// render.
//

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return HONEY.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := HONEY.BalanceOf(owner.Resolve())
		return ufmt.Sprintf("%d\n", balance)
	default:
		return "404\n"
	}
}

func assertIsAdmin(address std.Address) {
	if address != admin {
		panic("restricted access")
	}
}