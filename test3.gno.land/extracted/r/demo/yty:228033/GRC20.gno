package yty

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	yty  *grc20.AdminToken
	admin std.Address = "g1hqzeju0p0eup9rgxa0pxvyc0y7wnzjrdvppsy5"
)

func init() {
	yty = grc20.NewAdminToken("ytyToken", "yty", 6)
	yty.Mint(admin, 1000000000) // @administrator
}

// method proxies as public functions.
//

// getters.

func TotalSupply() uint64 {
	return yty.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := yty.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spenyty users.AddressOrName) uint64 {
	allowance, err := yty.Allowance(owner.Resolve(), spenyty.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	yty.Transfer(caller, to.Resolve(), amount)
}

func Approve(spenyty users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	yty.Approve(caller, spenyty.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	yty.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	yty.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	yty.Burn(address.Resolve(), amount)
}

// renyty.
//

func Renyty(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return yty.RenytyHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := yty.BalanceOf(owner.Resolve())
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