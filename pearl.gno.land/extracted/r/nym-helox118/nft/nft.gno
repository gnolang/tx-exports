package nft

import (
	"gno.land/p/nym-helox118/grc721"
	"gno.land/p/nt/seqid/v0"
)

var (
	token  *grc721.Token
	ledger *grc721.PrivateLedger
)

func CreateCollection(cur realm) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}

	if token != nil {
		panic("collection already created")
	}

	var collectionID seqid.ID
	token, ledger = grc721.NewToken(
		"Pearl NFT",
		"PNFT",
		collectionID,
		cur,
	)
}

func Mint(cur realm, tokenID string) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}

	if ledger == nil {
		panic("collection has not been created")
	}

	if tokenID == "" {
		panic("token ID cannot be empty")
	}

	err := ledger.Mint(
		cur.Previous().Address(),
		grc721.TokenID(tokenID),
	)
	if err != nil {
		panic(err)
	}
}

func OwnerOf(tokenID string) address {
	if ledger == nil {
		panic("collection has not been created")
	}

	owner, err := token.OwnerOf(grc721.TokenID(tokenID))
	if err != nil {
		panic(err)
	}

	return owner
}

func BalanceOf(owner address) int64 {
	if token == nil {
		panic("collection has not been created")
	}

	balance, err := token.BalanceOf(owner)
	if err != nil {
		panic(err)
	}

	return balance
}

func Render(_ string) string {
	if token == nil {
		return "Pearl NFT collection belum dibuat."
	}

	return "Pearl NFT\n" +
		"Name: " + token.GetName() + "\n" +
		"Symbol: " + token.GetSymbol() + "\n" +
		"Total supply: " + string(token.TotalSupply())
}
