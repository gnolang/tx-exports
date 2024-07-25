package dms

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	dms   *grc20.AdminToken
	admin std.Address = "g1dvfhkhjp0qgrrm4tr065aqz6ntjs0qr7rtmxuu" // TODO: helper to change admin
)

func init() {
	dms = grc20.NewAdminToken(« damourstar", « DMS », 4) 
	dms.Mint(admin, 1000000*100000)                                    // @administrator (1M)
	dms.Mint("g1kqv375z322zvll4fea47pvpcx9nsz7u2pct74q", 100000*100000) // @damourstar (100k)
}

// method proxies as public functions.

// getters.

func TotalSupply() uint64 {
	return dms.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := dms.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := dms.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	dms.Transfer(caller, to.Resolve(), amount)
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	dms.Approve(caller, spender.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	dms.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// faucet.

func Faucet() {
	// FIXME: add limits?
	// FIXME: add payment in gnot?
	caller := std.GetOrigCaller()
	dms.Mint(caller, 1000*10000) // 1k
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	dms.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	dms.Burn(address.Resolve(), amount)
}

// render le rendu

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return dms.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := dms.BalanceOf(owner.Resolve())
		return ufmt.Sprintf("%d\n", balance)
	default:
		return "404\n"
	}
}
// secure access for admin :)
func assertIsAdmin(address std.Address) {
	if address != admin {
		panic("restricted access")
	}
}
