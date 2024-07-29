package gslice20

import (
    "std"
    "strings"

    "gno.land/p/demo/grc/grc20"
    "gno.land/p/demo/ownable"
    "gno.land/p/demo/ufmt"
    pusers "gno.land/p/demo/users"
    "gno.land/r/demo/users"
)

var (
    banker *grc20.Banker
    admin  *ownable.Ownable
    token  grc20.Token
)

func init() {
    admin = ownable.NewWithAddress("g1newadminaddress") // Replace with the actual admin address
    banker = grc20.NewBanker("gslice", "GSLICE", 4) // "gslice" is the name and "GSLICE" is the symbol
    banker.Mint(admin.Owner(), 1000000000*10000) // Initial minting (1 billion tokens)
    token = banker.Token()
}

func TotalSupply() uint64 {
    return token.TotalSupply()
}

func BalanceOf(owner pusers.AddressOrName) uint64 {
    ownerAddr := users.Resolve(owner)
    return token.BalanceOf(ownerAddr)
}

func Allowance(owner, spender pusers.AddressOrName) uint64 {
    ownerAddr := users.Resolve(owner)
    spenderAddr := users.Resolve(spender)
    return token.Allowance(ownerAddr, spenderAddr)
}

func Transfer(to pusers.AddressOrName, amount uint64) {
    toAddr := users.Resolve(to)
    checkErr(token.Transfer(toAddr, amount))
}

func Approve(spender pusers.AddressOrName, amount uint64) {
    spenderAddr := users.Resolve(spender)
    currentAllowance := token.Allowance(std.GetCaller(), spenderAddr)
    if currentAllowance != 0 {
        checkErr(token.Approve(spenderAddr, 0))
    }
    checkErr(token.Approve(spenderAddr, amount))
}

func TransferFrom(from, to pusers.AddressOrName, amount uint64) {
    fromAddr := users.Resolve(from)
    toAddr := users.Resolve(to)
    checkErr(token.TransferFrom(fromAddr, toAddr, amount))
}

func Mint(to pusers.AddressOrName, amount uint64) {
    admin.AssertCallerIsOwner() // Ensure only the admin can mint
    toAddr := users.Resolve(to)
    checkErr(banker.Mint(toAddr, amount))
}

func Burn(from pusers.AddressOrName, amount uint64) {
    admin.AssertCallerIsOwner() // Ensure only the admin can burn
    fromAddr := users.Resolve(from)
    checkErr(banker.Burn(fromAddr, amount))
}

func Render(path string) string {
    parts := strings.Split(path, "/")
    c := len(parts)

    switch {
    case path == "":
        return banker.RenderHome()
    case c == 2 && parts[0] == "balance":
        owner := pusers.AddressOrName(parts[1])
        ownerAddr := users.Resolve(owner)
        balance := banker.BalanceOf(ownerAddr)
        return ufmt.Sprintf("%d\n", balance)
    default:
        return "404\n"
    }
}

func checkErr(err error) {
    if err != nil {
        // Proper error handling should be implemented here
        panic(err) // Replace with proper error handling if needed
    }
}
