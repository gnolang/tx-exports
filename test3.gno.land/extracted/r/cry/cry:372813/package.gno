package cry

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
)

var (
	cry   *grc20.AdminToken
	admin std.Address = "g1p9ap4pqc74uwek9zqk0kxx9wq90ljpyz9av6lc" // TODO: helper to change admin
)

func init() {
	cry = grc20.NewAdminToken("Cryptopunkstar", "cry", 4)
	cry.Mint(admin, 1000000*100000)                                    // @administrator (1M)
	cry.Mint("g1f748xee7gpwldyrz4xea3nk6hw24lfya49fus8", 100000*100000) // @cryptopunkstar (100k)
}

// method proxies as public functions.

// getters.

func TotalSupply() uint64 {
	return cry.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := cry.BalanceOf(owner.Resolve())
	if err != nil {
		panic(err)
	}
	return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := cry.Allowance(owner.Resolve(), spender.Resolve())
	if err != nil {
		panic(err)
	}
	return allowance
}

// setters.

func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	cry.Transfer(caller, to.Resolve(), amount)
}

func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	cry.Approve(caller, spender.Resolve(), amount)
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	cry.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
}

// faucet.

func Faucet() {
	// FIXME: add limits?
	// FIXME: add payment in gnot?
	caller := std.GetOrigCaller()
	cry.Mint(caller, 1000*10000) // 1k
}

// administration.

func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	cry.Mint(address.Resolve(), amount)
}

func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	cry.Burn(address.Resolve(), amount)
}

// render le rendu

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return cry.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := cry.BalanceOf(owner.Resolve())
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