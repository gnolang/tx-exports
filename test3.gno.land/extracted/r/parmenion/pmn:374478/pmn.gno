package pmn

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	pmn   *grc20.AdminToken
	admin std.Address = "g1zd3aykct4yr4steu6f6n9t9z9emwhrkc0wgzef" // TODO: helper to change admin
)

func init() {
	pmn = grc20.NewAdminToken("Parmenion", "PMN", 4)
	pmn.Mint(admin, 1000000*100000)                                    // @administrator (1M)
	pmn.Mint("g1yzzpazt7rtp0xzve33t6mmdvlfevdg0pw9jzts", 100000*100000) // @cryptopunkstar (100k)
}

// method proxies as public functions.

// getters.

func TotalSupply() uint64 {
	return pmn.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := pmn.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := pmn.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	pmn.Transfer(caller, to.Resolve(), amount)
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	pmn.Approve(caller, spender.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	pmn.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// faucet.

func Faucet() {
	// FIXME: add limits?
	// FIXME: add payment in gnot?
	caller := std.GetOrigCaller()
	pmn.Mint(caller, 1000*10000) // 1k
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	pmn.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	pmn.Burn(address.Resolve(), amount)
}

// render le rendu

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return pmn.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := pmn.BalanceOf(owner.Resolve())
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