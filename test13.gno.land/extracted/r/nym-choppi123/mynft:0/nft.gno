package mynft

import "strconv"

var (
    name        string = "MyNFTCollection"
    symbol      string = "MNFT"
    totalSupply uint64 = 0
    nfts        map[uint64]string
    owners      map[string][]uint64
)

func init() {
    nfts = make(map[uint64]string)
    owners = make(map[string][]uint64)
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

func OwnerOf(tokenID uint64) string {
    return nfts[tokenID]
}

func Mint(to string) uint64 {
    totalSupply++
    tokenID := totalSupply
    nfts[tokenID] = to
    owners[to] = append(owners[to], tokenID)
    return tokenID
}

func Render(path string) string {
    return "# " + name + " (" + symbol + ")\n\n" +
           "**Total NFTs:** " + strconv.FormatUint(totalSupply, 10) + "\n\n" +
           "**Collection de " + path + ":** " + strconv.Itoa(len(owners[path])) + " NFTs"
}
