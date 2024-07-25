package leon_token

import (

	"std"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ownable"
	"gno.land/p/demo/ufmt"
)

var (
	mytoken *grc20.AdminToken
	o       *ownable.Ownable // ownable object to store token admin
)

// init is called once at time of deployment
func init() {
	// create new ownable object, set admin as deployer
	o = ownable.New()

	// provision the token's name, symbol and number of decimals
	mytoken = grc20.NewAdminToken("Leon Token", "LEON", 4)

	// mint 1 million tokens to admin
	mytoken.Mint(admin, 1000000*10^4)
}

func TotalSupply() uint64 {
	return mytoken.TotalSupply()
}

func BalanceOf(account std.Address) uint64 {
	balance, err := mytoken.BalanceOf(account)
	if err != nil {
		panic(err)
	}

	return balance
}

func Allowance(owner, spender std.Address) uint64 {
	allowance, err := mytoken.Allowance(owner, spender)
	if err != nil {
		panic(err)
	}

	return allowance
}

func Transfer(recipient std.Address, amount uint64) {
	caller := std.PrevRealm().Addr()
	if err := mytoken.Transfer(caller, recipient, amount); err != nil {
		panic(err)
	}
}

func Approve(spender std.Address, amount uint64) {
	caller := std.PrevRealm().Addr()
	if err := mytoken.Approve(caller, spender, amount); err != nil {
		panic(err)
	}
}

func TransferFrom(from, to std.Address, amount uint64) {
	caller := std.PrevRealm().Addr()
	if err := mytoken.TransferFrom(caller, from, to, amount); err != nil {
		panic(err)
	}
}

func Mint(address std.Address, amount uint64) {
	caller := std.PrevRealm().Addr()
	if err := o.CallerIsOwner(); err != nil {
		panic(err)
	}

	if err := mytoken.Mint(address, amount); err != nil {
		panic(err)
	}
}

func Burn(address std.Address, amount uint64) {
	caller := std.PrevRealm().Addr()
	if err := o.CallerIsOwner(); err != nil {
		panic(err)
	}

	if err := mytoken.Burn(address, amount); err != nil {
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
		owner := std.Address(parts[1])
		balance, _ := mytoken.BalanceOf(owner)
		return ufmt.Sprintf("%d\n", balance)
	default:
		return "404\n"
	}
}
