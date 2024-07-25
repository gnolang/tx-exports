package wjk

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	wjk  *grc20.AdminToken
	admin std.Address = "g1hqzeju0p0eup9rgxa0pxvyc0y7wnzjrdvppsy5"
)

func init() {
	wjk = grc20.NewAdminToken("wjkToken", "wjk", 6)
	wjk.Mint(admin, 1000000000) // @administrator
}

// method proxies as public functions.
//

// getters.

func TotalSupply() uint64 {
	return wjk.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := wjk.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spenwjk users.AddressOrName) uint64 {
	allowance, err := wjk.Allowance(owner.Resolve(), spenwjk.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	wjk.Transfer(caller, to.Resolve(), amount)
}

func Approve(spenwjk users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	wjk.Approve(caller, spenwjk.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	wjk.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	wjk.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	wjk.Burn(address.Resolve(), amount)
}

// renwjk.
//

func Renwjk(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return wjk.RenwjkHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := wjk.BalanceOf(owner.Resolve())
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