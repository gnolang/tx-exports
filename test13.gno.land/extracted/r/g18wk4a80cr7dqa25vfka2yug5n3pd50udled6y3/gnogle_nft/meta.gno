package gnogle_nft

import (
	"chain"
	"strconv"

	"gno.land/p/g18wk4a80cr7dqa25vfka2yug5n3pd50udled6y3/grc721"
)

// Burn permanently destroys a token the caller owns.
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

// SealCollection caps supply at the current minted count (burns the unminted
// remainder). Creator-only, irreversible.
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

// SetBaseURI updates a collection's metadata base URI (e.g. after pinning to
// IPFS). Creator-only.
func SetBaseURI(cur realm, collID, uri string) {
	assertUserCall(cur)
	coll := mustGetCollection(collID)
	if cur.Previous().Address() != coll.creator {
		panic("only the collection creator can set the base URI")
	}
	coll.baseURI = uri
	chain.Emit("SetBaseURI", "collection", collID)
}

// SetVerified toggles a collection's verified badge. Admin-only.
func SetVerified(cur realm, collID string, v bool) {
	assertAdmin(cur)
	coll := mustGetCollection(collID)
	coll.verified = v
	chain.Emit("SetVerified", "collection", collID, "verified", strconv.FormatBool(v))
}
