package gnogle_nftmarket

import (
	"chain"
	"strconv"

	"gno.land/p/nt/ufmt/v0"
)

// MintBatch mints `count` (1..20) tokens to the caller in one call, charging
// count × the mint price. Returns the first token id minted.
func MintBatch(cur realm, collID string, count int64) string {
	assertUserCall(cur)
	if count <= 0 || count > 20 {
		panic("count must be between 1 and 20")
	}
	coll := mustGetCollection(collID)
	minter := cur.Previous().Address()

	paid := receivedUgnot()
	if paid != coll.mintPrice*count {
		panic(ufmt.Sprintf("must send exactly %d ugnot for %d mints", coll.mintPrice*count, count))
	}

	first := ""
	for i := int64(0); i < count; i++ {
		tid := mintOne(coll, minter)
		if first == "" {
			first = tid
		}
	}
	if paid > 0 {
		payout(cur, coll.creator, paid)
	}
	chain.Emit("MintBatch", "collection", collID, "count", strconv.FormatInt(count, 10), "minter", minter.String())
	return first
}

// SetBaseURI updates a collection's metadata base URI (e.g. after pinning images
// to IPFS). Creator-only.
func SetBaseURI(cur realm, collID, uri string) {
	assertUserCall(cur)
	coll := mustGetCollection(collID)
	if cur.Previous().Address() != coll.creator {
		panic("only the collection creator can set the base URI")
	}
	coll.baseURI = uri
	chain.Emit("SetBaseURI", "collection", collID)
}

// SetVerified toggles a collection's "verified" badge. Admin-only.
func SetVerified(cur realm, collID string, v bool) {
	assertAdmin(cur)
	coll := mustGetCollection(collID)
	coll.verified = v
	chain.Emit("SetVerified", "collection", collID, "verified", strconv.FormatBool(v))
}
