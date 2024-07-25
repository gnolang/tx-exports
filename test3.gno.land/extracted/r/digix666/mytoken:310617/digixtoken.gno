package mytoken

import (
    "std"
    "gno.land/p/demo/grc/grc20"
    "strings"
    "gno.land/p/demo/ufmt"
    "gno.land/r/demo/users"
)

var (
    mytoken *grc20.AdminToken
    admin   std.Address = "g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj" // set admin account
)

// init is a constructor function that runs only once (at time of deployment)
func init() {
    // provision the token's name, symbol and number of decimals
    mytoken = grc20.NewAdminToken("Mytoken", "MTKN", 4)

    // set the total supply
    mytoken.Mint(admin, 1000000*10000) // @administrator (supply = 1 million)
}

func TotalSupply() uint64 {
    return mytoken.TotalSupply()
}

func BalanceOf(owner users.AddressOrName) uint64 {
    balance, err := mytoken.BalanceOf(users.Resolve(owner))
    if err != nil {
        panic(err)
    }
    return balance
}

func Allowance(owner, spender users.AddressOrName) uint64 {
    allowance, err := mytoken.Allowance(users.Resolve(owner), users.Resolve(spender))
    if err != nil {
        panic(err)
    }
    return allowance
}

func Transfer(to users.AddressOrName, amount uint64) {
    caller := std.PrevRealm().Addr()
    err := mytoken.Transfer(caller, users.Resolve(to), amount)
    if err != nil {
        panic(err)
    }
}

func Approve(spender users.AddressOrName, amount uint64) {
    caller := std.PrevRealm().Addr()
    err := mytoken.Approve(caller, users.Resolve(spender), amount)
    if err != nil {
        panic(err)
    }
}

func TransferFrom(from, to users.AddressOrName, amount uint64) {
    caller := std.PrevRealm().Addr()
    err := mytoken.TransferFrom(caller, users.Resolve(from), users.Resolve(to), amount)
    if err != nil {
        panic(err)
    }
}

func Mint(address users.AddressOrName, amount uint64) {
    caller := std.PrevRealm().Addr()
    assertIsAdmin(caller)
    err := mytoken.Mint(users.Resolve(address), amount)
    if err != nil {
        panic(err)
    }
}

func Burn(address users.AddressOrName, amount uint64) {
    caller := std.PrevRealm().Addr()
    assertIsAdmin(caller)
    err := mytoken.Burn(users.Resolve(address), amount)
    if err != nil {
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
        owner := users.AddressOrName(parts[1])
        balance, _ := mytoken.BalanceOf(users.Resolve(owner))
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