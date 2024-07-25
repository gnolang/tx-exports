package res

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	res   *grc20.AdminToken
	admin std.Address = "g13jt6wq3z2mp2wg9dkcejn046f8fnyu74002ftq" // TODO: helper to change admin
)

func init() {
	res = grc20.NewAdminToken("res", "RES", 4)
	res.Mint(admin, 1000000*100000)                                    // @administrator (1M)
	res.Mint("g142nyevvsxcezxfmq4pc2eja96mxrvm75xdymf5", 100000*100000) // @cryptopunkstar (100k)
}

// method proxies as public functions.

// getters.

func TotalSupply() uint64 {
	return res.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := res.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := res.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	res.Transfer(caller, to.Resolve(), amount)
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	res.Approve(caller, spender.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	res.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// faucet.

func Faucet() {
	// FIXME: add limits?
	// FIXME: add payment in gnot?
	caller := std.GetOrigCaller()
	res.Mint(caller, 1000*10000) // 1k
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	res.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	res.Burn(address.Resolve(), amount)
}

// render le rendu

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return res.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := res.BalanceOf(owner.Resolve())
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