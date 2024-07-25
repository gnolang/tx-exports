package mytoken

import (
	"std"
	"strings"
	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/users"
	"gno.land/p/demo/ufmt"
)

var (
	mytoken *grc20.AdminToken
	admin   std.Address = "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj" // set admin account
)

// init is a constructor function that runs only once (at time of deployment)
func init() {
	// provision the token's name, symbol and number of decimals
	mytoken = grc20.NewAdminToken("Mytoken", "MTKN", 4)

	// set the total supply
	mytoken.Mint(admin, 1000000*10000) // @administrator (supply = 1 million)
}

func TotalSupply() uint64 {
	return mytoken.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := mytoken.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := mytoken.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.PrevRealm().Addr()
	err := mytoken.Transfer(caller, to.Resolve(), amount)
	if err != nil {
		panic(err)
	}
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.PrevRealm().Addr()
	err := mytoken.Approve(caller, spender.Resolve(), amount)
	if err != nil {
		panic(err)
	}
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.PrevRealm().Addr()
	err := mytoken.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
	if err != nil {
		panic(err)
	}
}

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := mytoken.Mint(address.Resolve(), amount)
	if err != nil {
		panic(err)
	}
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	err := mytoken.Burn(address.Resolve(), amount)
	if err != nil {
		panic(err)
	}
}

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return mytoken.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := mytoken.BalanceOf(owner.Resolve())
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

