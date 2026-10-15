package pearlnft

import (
	"strconv"
	"gno.land/p/nym-config058/grc721"
)

var (
	Token         *grc721.Token
	privateLedger *grc721.PrivateLedger
)

func init(cur realm) {
	Token, privateLedger = grc721.NewToken("Pearl Demo NFT", "PNFT", 0, cur)
}

// Mint creates an NFT for the caller. This is intentionally open for testing.
func Mint(cur realm, tokenID string) {
	caller := cur.Previous().Address()
	err := privateLedger.Mint(caller, grc721.TokenID(tokenID))
	if err != nil {
		panic(err)
	}
}

func TotalSupply() int64 {
	return Token.TotalSupply()
}

func BalanceOf(owner address) int64 {
	balance, err := Token.BalanceOf(owner)
	if err != nil {
		panic(err)
	}
	return balance
}

func OwnerOf(tokenID string) address {
	owner, err := Token.OwnerOf(grc721.TokenID(tokenID))
	if err != nil {
		panic(err)
	}
	return owner
}

func Render(path string) string {
	return "Pearl Demo NFT\n\nCollection: " + Token.GetName() +
		"\nSymbol: " + Token.GetSymbol() +
		"\nTotal supply: " + strconv.Itoa(int(Token.TotalSupply()))
}
