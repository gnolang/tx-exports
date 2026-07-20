package mytoken

import "strconv"

var (
    name        string = "MyToken"
    symbol      string = "MTK"
    decimals    uint   = 6
    totalSupply uint64 = 1000000000000
    balances    map[string]uint64
)

func init() {
    balances = make(map[string]uint64)
    balances["g1p4r3esnxhahp307gh5kplvnjxdgy8kguvf9znu"] = totalSupply
}

func GetName() string {
    return name
}

func GetSymbol() string {
    return symbol
}

func GetDecimals() uint {
    return decimals
}

func GetTotalSupply() uint64 {
    return totalSupply
}

func BalanceOf(owner string) uint64 {
    return balances[owner]
}

func Render(path string) string {
    return "# " + name + " (" + symbol + ")\n\n" +
           "**Total Supply:** " + strconv.FormatUint(totalSupply, 10) + "\n\n" +
           "**Your Balance:** " + strconv.FormatUint(BalanceOf(path), 10)
}
