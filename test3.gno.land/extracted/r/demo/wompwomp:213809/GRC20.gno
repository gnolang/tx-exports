package wompwomp

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	wompwomp  *grc20.AdminToken
	admin std.Address = "g1sycj68ur0n7xytglx0me3f207ktudm80aqpysm"
)

func init() {
	wompwomp = grc20.NewAdminToken("wompwompToken", "wompwomp", 6)
	wompwomp.Mint(admin, 1000000000) // @administrator
}

// method proxies as public functions.
//

// getters.

func TotalSupply() uint64 {
	return wompwomp.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := wompwomp.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := wompwomp.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	wompwomp.Transfer(caller, to.Resolve(), amount)
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	wompwomp.Approve(caller, spender.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	wompwomp.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	wompwomp.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	wompwomp.Burn(address.Resolve(), amount)
}

// render.
//

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return wompwomp.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := wompwomp.BalanceOf(owner.Resolve())
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