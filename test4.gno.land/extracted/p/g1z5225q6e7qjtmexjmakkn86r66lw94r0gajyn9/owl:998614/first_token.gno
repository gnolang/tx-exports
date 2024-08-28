package owl

import (
	"std"
	"strings"
	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
)

var (
  	owl     grc20.AdminToken
	admin   std.Address = "g1z5225q6e7qjtmexjmakkn86r66lw94r0gajyn9"
)

// init is called once at time of deployment
func init() {
	// Set deployer of Realm to admin
	admin = std.PrevRealm().Addr()

	// Set token name, symbol and number of decimals
	owl = grc20.NewAdminToken("Coruja", "OWL", 4)

	// Mint 1 million tokens to admin
	owl.Mint(admin, 1000000*10000)
}

func TotalSupply() uint64 {
	return owl.TotalSupply()
}

func Decimals() uint {
	return owl.GetDecimals()
}

func BalanceOf(account std.Address) uint64 {
	balance, err := owl.BalanceOf(account)
	if err != nil {
		panic(err)
	}

	return balance
}

func Allowance(owner, spender std.Address) uint64 {
	allowance, err := owl.Allowance(owner, spender)
	if err != nil {
		panic(err)
	}

	return allowance
}

func Transfer(recipient std.Address, amount uint64) {
	caller := std.PrevRealm().Addr()
	if err := owl.Transfer(caller, recipient, amount); err != nil {
		panic(err)
	}
}

func Approve(spender std.Address, amount uint64) {
	caller := std.PrevRealm().Addr()
	if err := owl.Approve(caller, spender, amount); err != nil {
		panic(err)
	}
}

func TransferFrom(sender, recipient std.Address, amount uint64) {
    caller := std.PrevRealm().Addr()

    if amount <= 0 {
        panic("transfer amount must be greater than zero")
    }

    if err := owl.TransferFrom(caller, sender, recipient, amount); err != nil {
        panic(err)
    }
}

func Mint(address std.Address, amount uint64) {
	assertIsAdmin(std.PrevRealm().Addr())

	if amount <= 0 {
		panic("mint amount must be greater than zero")
	}

	if err := owl.Mint(address, amount); err != nil {
		panic(err)
	}
}

func Burn(address std.Address, amount uint64) {
	assertIsAdmin(std.PrevRealm().Addr())

	if amount <= 0 {
		panic("burn amount must be greater than zero")
	}

	if err := owl.Burn(address, amount); err != nil {
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
		return owl.RenderHome()
	case c == 2 && parts[0] == "balance":
		owner := std.Address(parts[1])
		balance, _ := owl.BalanceOf(owner)
		return ufmt.Sprintf("%d\n", balance)
	default:
		return "404\n"
	}
}
// How-to: Create a GRC20 Token