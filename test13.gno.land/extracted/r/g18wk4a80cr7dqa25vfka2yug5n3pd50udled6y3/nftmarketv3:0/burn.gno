package nftmarket

import (
	"chain"
	"strconv"

	"gno.land/p/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/grc721"
)

// Burn permanently destroys a token the caller owns. The token must be held
// directly by the caller (not escrowed in a listing or auction).
func Burn(cur realm, collID, tokenID string) {
	assertUserCall(cur)
	coll := mustGetCollection(collID)
	caller := cur.Previous().Address()
	tid := grc721.TokenID(tokenID)

	owner, err := coll.nft.OwnerOf(tid)
	if err != nil {
		panic(err)
	}
	if owner != caller {
		panic("only the token owner can burn it")
	}
	if err := coll.nft.Burn(tid); err != nil {
		panic(err)
	}
	coll.burned++

	chain.Emit("Burn", "collection", collID, "tokenId", tokenID, "by", caller.String())
}

// SealCollection caps a collection at its current minted count, permanently
// "burning" the unminted remainder so no further tokens can be minted.
// Creator-only and irreversible — useful when you created a large supply but
// minted only part of it.
func SealCollection(cur realm, collID string) {
	assertUserCall(cur)
	coll := mustGetCollection(collID)
	if cur.Previous().Address() != coll.creator {
		panic("only the collection creator can seal it")
	}
	coll.maxSupply = coll.minted
	coll.sealed = true

	chain.Emit("CollectionSealed", "collection", collID, "supply", strconv.FormatInt(coll.minted, 10))
}
