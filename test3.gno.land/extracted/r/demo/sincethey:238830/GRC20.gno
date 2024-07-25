package sincethey

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	sincethey  *grc20.AdminToken
	admin std.Address = "g1mvmue4j23xtz6xe9tpfr42m4yg83pxrxtlz2e2"
)

func init() {
	sincethey = grc20.NewAdminToken("sincetheyToken", "sincethey", 6)
	sincethey.Mint(admin, 1000000000) // @administrator
}

// method proxies as public functions.
//

// getters.

func TotalSupply() uint64 {
	return sincethey.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := sincethey.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := sincethey.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	sincethey.Transfer(caller, to.Resolve(), amount)
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	sincethey.Approve(caller, spender.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	sincethey.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	sincethey.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	sincethey.Burn(address.Resolve(), amount)
}

// render.
//

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return sincethey.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := sincethey.BalanceOf(owner.Resolve())
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