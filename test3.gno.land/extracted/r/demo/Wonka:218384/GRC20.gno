package Wonka

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	Wonka  *grc20.AdminToken
	admin std.Address = "g1m8gl02h5cumulxgncfp7w507xaw5f43lsl4xzq"
)

func init() {
	Wonka = grc20.NewAdminToken("WonkaToken", "Wonka", 6)
	Wonka.Mint(admin, 1000000000) // @administrator
}

// method proxies as public functions.
//

// getters.

func TotalSupply() uint64 {
	return Wonka.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := Wonka.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := Wonka.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	Wonka.Transfer(caller, to.Resolve(), amount)
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	Wonka.Approve(caller, spender.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	Wonka.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	Wonka.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	Wonka.Burn(address.Resolve(), amount)
}

// render.
//

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return Wonka.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := Wonka.BalanceOf(owner.Resolve())
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