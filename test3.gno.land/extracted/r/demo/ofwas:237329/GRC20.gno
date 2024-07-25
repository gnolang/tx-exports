package ofwas

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	ofwas  *grc20.AdminToken
	admin std.Address = "g1scre45qu5rwqhlfl6qj65jm9lvns6xajklxz3x	"
)

func init() {
	ofwas = grc20.NewAdminToken("ofwasToken", "ofwas", 6)
	ofwas.Mint(admin, 1000000000) // @administrator
}

// method proxies as public functions.
//

// getters.

func TotalSupply() uint64 {
	return ofwas.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := ofwas.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := ofwas.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	ofwas.Transfer(caller, to.Resolve(), amount)
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	ofwas.Approve(caller, spender.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	ofwas.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	ofwas.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	ofwas.Burn(address.Resolve(), amount)
}

// render.
//

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return ofwas.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := ofwas.BalanceOf(owner.Resolve())
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