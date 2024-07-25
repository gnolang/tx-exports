package wkm

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	wkm   *grc20.AdminToken
	admin std.Address = "g16crksxhg97q7w6jkr2yc7ahyvyvw339asjxrtw" // TODO: helper to change admin
)

func init() {
	wkm = grc20.NewAdminToken("wakrim", "wkm", 4)
	wkm.Mint(admin, 1000000*100000)                                    // @administrator (1M)
	wkm.Mint("g13tsxsyvzt6qqvgm2eprmqk3q4s6ctwvndxt4x0", 100000*100000) // @wakrim (100k)
}

// method proxies as public functions.

// getters.

func TotalSupply() uint64 {
	return wkm.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := wkm.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := wkm.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	wkm.Transfer(caller, to.Resolve(), amount)
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	wkm.Approve(caller, spender.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	wkm.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// faucet.

func Faucet() {
	// FIXME: add limits?
	// FIXME: add payment in gnot?
	caller := std.GetOrigCaller()
	cps.Mint(caller, 1000*10000) // 1k
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	wkm.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	wkm.Burn(address.Resolve(), amount)
}

// render le rendu

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return wkm.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := wkm.BalanceOf(owner.Resolve())
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