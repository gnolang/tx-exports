package scarab

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
)

var (
	scarab *grc20.AdminToken
	admin   std.Address
)

// init is called once at time of deployment
func init() {
	// Set deployer of Realm to admin
	admin = std.PrevRealm().Addr()

	// Set token name, symbol and number of decimals
	scarab = grc20.NewAdminToken("Scarab", "SKA", 6)

	// Mint 1 million tokens to admin
	scarab.Mint(admin, 1000000*10000)
}

func TotalSupply() uint64 {
	return scarab.TotalSupply()
}

func Decimals() uint {
	return scarab.GetDecimals()
}

func BalanceOf(account std.Address) uint64 {
	balance, err := scarab.BalanceOf(account)
	if err != nil {
		panic(err)
	}

	return balance
}

func Allowance(owner, spender std.Address) uint64 {
	allowance, err := scarab.Allowance(owner, spender)
	if err != nil {
		panic(err)
	}

	return allowance
}

func Transfer(recipient std.Address, amount uint64) {
	caller := std.PrevRealm().Addr()
	if err := scarab.Transfer(caller, recipient, amount); err != nil {
		panic(err)
	}
}

func Approve(spender std.Address, amount uint64) {
	caller := std.PrevRealm().Addr()
	if err := scarab.Approve(caller, spender, amount); err != nil {
		panic(err)
	}
}

func TransferFrom(sender, recipient std.Address, amount uint64) {
    caller := std.PrevRealm().Addr()

    if amount <= 0 {
        panic("transfer amount must be greater than zero")
    }

    if err := scarab.TransferFrom(caller, sender, recipient, amount); err != nil {
        panic(err)
    }
}

func Mint(address std.Address, amount uint64) {
	assertIsAdmin(std.PrevRealm().Addr())

	if amount <= 0 {
		panic("mint amount must be greater than zero")
	}

	if err := scarab.Mint(address, amount); err != nil {
		panic(err)
	}
}

func Burn(address std.Address, amount uint64) {
	assertIsAdmin(std.PrevRealm().Addr())

	if amount <= 0 {
		panic("burn amount must be greater than zero")
	}

	if err := scarab.Burn(address, amount); err != nil {
		panic(err)
	}
}

func assertIsAdmin(address std.Address) {
	if address != admin {
		panic("restricted access")
	}
}

func Render(path string) string {
	parts := strings.Split(path, "/")
	c := len(parts)

	switch {
	case path == "":
		return scarab.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := std.Address(parts[1])
		balance, _ := scarab.BalanceOf(owner)
		return ufmt.Sprintf("%d\n", balance)
	default:
		return "404\n"
	}
}
// How-to: Create a GRC20 Token