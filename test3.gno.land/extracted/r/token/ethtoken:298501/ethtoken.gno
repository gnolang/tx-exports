package ethtoken

import (
	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
	"gno.land/r/demo/users"
	"std"
    "strings"
)

var (
	ethtoken *grc20.AdminToken
	admin    std.Address = "g1v664qx78zhv2edtx6ypdylfpafrqjz8g2rlaea"
)

func init() {
	ethtoken = grc20.NewAdminToken("Ethereum", "ETH", 4)
	ethtoken.Mint(admin, 1000000*1000000)
}

// Return total numbers tokens minted
func TotalSupply() uint64 {
	return ethtoken.TotalSupply()
}

// Return total balance account
func BalanceOf(owner users.AddressOrName) uint64 {
	balance, err := ethtoken.BalanceOf(owner.Resolve())

	if err != nil {
		panic(err)
	}

	return balance
}

// Set an account as an allowed spender to serve on behalf of the owner
func Allowance(owner, spender users.AddressOrName) uint64 {
	allowance, err := ethtoken.Allowance(owner.Resolve(), spender.Resolve())

	if err != nil {
		panic(err)
	}

	return allowance
}

// Transfer amount to another account
func Transfer(to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	err := ethtoken.Transfer(caller, to.Resolve(), amount)

	if err != nil {
		panic(err)
	}
}

// Approve a calling account to spend a configurale amount of token on behalf of the token owner
func Approve(spender users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	err := ethtoken.Approve(caller, spender.Resolve(), amount)

	if err != nil {
		panic(err)
	}
}

// Transfer amount of token from an account that granted approval to another account
func TransferFrom(from, to users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	err := ethtoken.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)

	if err != nil {
		panic(err)
	}
}

// Create a configurable number of token by the admin
func Mint(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	err := ethtoken.Mint(address.Resolve(), amount)

	if err != nil {
		panic(err)
	}
}

// Destroy a configurable number of token by the amdin
func Burn(address users.AddressOrName, amount uint64) {
	caller := std.GetOrigCaller()
	assertIsAdmin(caller)
	err := ethtoken.Burn(address.Resolve(), amount)

	if err != nil {
		panic(err)
	}
}

// Return a user's balance as a formatted string
func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return ethtoken.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := users.AddressOrName(parts[1])
		balance, _ := ethtoken.BalanceOf(owner.Resolve())
		return ufmt.Sprintf("%d\n", balance)
	default:
		return "404\n"
	}
}

// Verify if address is admin
func assertIsAdmin(address std.Address) {
	if address != admin {
		panic("restricted access")
	}
}