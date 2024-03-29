package wgnot

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"

	// for swap
	"gno.land/p/demo/testutils"
)

var (
	wgnot *grc20.AdminToken
	admin std.Address = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5" // TODO: helper to change admin
)

func init() {
	wgnot = grc20.NewAdminToken("WrappedGnot", "WGNOT", 4) // name, symbol, decimals
	wgnot.Mint(admin, 1000000*10000)                       // @administrator (1M)

	// for swap > pool
	var (
		lp01     = testutils.TestAddress("lp01") // Liquidity Provider 01
		lp02     = testutils.TestAddress("lp02") // Liquidity Provider 02
		lp03     = testutils.TestAddress("lp03") // Liquidity Provider 03
		tr01     = testutils.TestAddress("tr01") // Trader 01
		poolAddr = std.DerivePkgAddr("gno.land/r/pool")
		posAddr  = std.DerivePkgAddr("gno.land/r/position")
	)

	wgnot.Mint(lp01, 50000000)
	wgnot.Mint(lp02, 50000000)
	wgnot.Mint(lp03, 50000000)
	wgnot.Mint(tr01, 50000000)

	wgnot.Approve(lp01, poolAddr, 50000000)
	wgnot.Approve(lp02, poolAddr, 50000000)
	wgnot.Approve(lp03, poolAddr, 50000000)
	wgnot.Approve(tr01, poolAddr, 50000000)

	wgnot.Approve(lp01, lp01, 50000000)
	wgnot.Approve(lp02, lp02, 50000000)
	wgnot.Approve(lp03, lp03, 50000000)
	wgnot.Approve(tr01, tr01, 50000000)

	wgnot.Approve(posAddr, poolAddr, 50000000)
}

// method proxies as public functions.
//

// getters.
func GetGRC20() *grc20.AdminToken {
	return wgnot
}

func TotalSupply() uint64 {
	return wgnot.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := wgnot.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := wgnot.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	// caller := std.GetOrigCaller()
	caller := std.PrevRealm().Addr()
	err := wgnot.Transfer(caller, to.Resolve(), amount)
	if err != nil {
		panic(err.Error())
	}
}

func Approve(spender users.AddressOrName, amount uint64) {
	// caller := std.GetOrigCaller()
	caller := std.PrevRealm().Addr()
	err := wgnot.Approve(caller, spender.Resolve(), amount)
	if err != nil {
		panic(err.Error())
	}
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	// caller := std.GetOrigCaller()
	caller := std.PrevRealm().Addr()
	err := wgnot.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
	if err != nil {
		panic(err.Error())
	}
}

// faucet.

func Faucet() {
	// FIXME: add limits?
	// FIXME: add payment in gnot?
	// caller := std.GetOrigCaller()
	caller := std.PrevRealm().Addr()
	wgnot.Mint(caller, 1000*10000) // 1k
}

func FaucetL() {
	// FIXME: add limits?
	// FIXME: add payment in gnot?
	// caller := std.GetOrigCaller()
	caller := std.PrevRealm().Addr()
	wgnot.Mint(caller, 50000000000) // 50_000_000_000
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	// caller := std.GetOrigCaller()
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	wgnot.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	// caller := std.GetOrigCaller()
	caller := std.PrevRealm().Addr()
	assertIsAdmin(caller)
	wgnot.Burn(address.Resolve(), amount)
}

// render.
//

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return wgnot.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := wgnot.BalanceOf(owner.Resolve())
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
