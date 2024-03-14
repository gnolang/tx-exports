package benz

import (
	"std"

	"gno.land/p/demo/grc/grc20"
)

var (
	benz  *grc20.AdminToken
	admin std.Address = "g1ayxdpq5jzqrkedjp57xvdhvf9g6jjwhxt5wn2f" // set admin account
)

// init is a constructor function that runs only once (at time of deployment)
func init() {
	// provision the token's name, symbol and number of decimals
	benz = grc20.NewAdminToken("Benz", "MTKN", 4)

	// set the total supply
	benz.Mint(admin, 1000000*10000) // @administrator (supply = 1 million)
}
func TotalSupply() uint64 {
    return benz.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
    balance, err := benz.BalanceOf(owner.Resolve())
    if err != nil {
        panic(err)
    }
    return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
    allowance, err := benz.Allowance(owner.Resolve(), spender.Resolve())
    if err != nil {
        panic(err)
    }
    return allowance
}

func Transfer(to users.AddressOrName, amount uint64) {
    caller := std.PrevRealm().Addr()
    err := benz.Transfer(caller, to.Resolve(), amount)
    if err != nil {
        panic(err)
    }
}

func Approve(spender users.AddressOrName, amount uint64) {
    caller := std.PrevRealm().Addr()
    err := benz.Approve(caller, spender.Resolve(), amount)
    if err != nil {
        panic(err)
    }
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
    caller := std.PrevRealm().Addr()
    err := benz.TransferFrom(caller, from.Resolve(), to.Resolve(), amount)
    if err != nil {
        panic(err)
    }
}

func Mint(address users.AddressOrName, amount uint64) {
    caller := std.PrevRealm().Addr()
    assertIsAdmin(caller)
    err := benz.Mint(address.Resolve(), amount)
    if err != nil {
        panic(err)
    }
}

func Burn(address users.AddressOrName, amount uint64) {
    caller := std.PrevRealm().Addr()
    assertIsAdmin(caller)
    err := benz.Burn(address.Resolve(), amount)
    if err != nil {
        panic(err)
    }
}

func Render(path string) string {
    parts := strings.Split(path, "/")
    c := len(parts)

    switch {
    case path == "":
        return benz.RenderHome()
    case c == 2 && parts[0] == "balance":
        owner := users.AddressOrName(parts[1])
        balance, _ := benz.BalanceOf(owner.Resolve())
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