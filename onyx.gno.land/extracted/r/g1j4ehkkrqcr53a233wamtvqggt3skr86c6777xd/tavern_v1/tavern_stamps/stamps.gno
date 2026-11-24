// An independent, freely mintable test collection with no creator royalty.
package tavern_stamps

import (
	"gno.land/p/nt/grc721/v0"
	"strconv"
)

var token *grc721.Token
var ledger *grc721.PrivateLedger
var teller grc721.Teller

func init(cur realm) {
	token, ledger = grc721.NewToken("Tavern Stamps", "STAMP", 0, cur)
	teller = ledger.CallerTeller()
}

func Claim(cur realm) string {
	id := strconv.FormatInt(token.TotalSupply()+1, 10)
	if err := ledger.Mint(cur.Previous().Address(), grc721.TokenID(id)); err != nil {
		panic(err)
	}
	return id
}

func OwnerOf(id string) address {
	owner, err := token.OwnerOf(grc721.TokenID(id))
	if err != nil {
		panic(err)
	}
	return owner
}

func TransferFrom(cur realm, from, to address, id string) {
	if cur.Previous().Address() != from {
		panic("owner required")
	}
	if err := teller.TransferFrom(0, cur, from, to, grc721.TokenID(id)); err != nil {
		panic(err)
	}
}
