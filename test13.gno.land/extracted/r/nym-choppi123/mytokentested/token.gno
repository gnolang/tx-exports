package mytokentested

import "strconv"

var (
    name        string = "MyTokenTested"
    symbol      string = "MTKT"
    totalSupply uint64 = 1000000
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

func GetTotalSupply() uint64 {
    return totalSupply
}

func BalanceOf(owner string) uint64 {
    return balances[owner]
}

func Render(path string) string {
    return "# " + name + "\n\nSupply: " + strconv.FormatUint(totalSupply, 10)
}
