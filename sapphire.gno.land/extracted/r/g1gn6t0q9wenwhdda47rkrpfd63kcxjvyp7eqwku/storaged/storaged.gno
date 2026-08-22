// Package storaged is storagea PLUS a GRC-721 mint per record, so the
// cost of minting a token can be separated from the cost of the record
// that owns it. Everything else is identical to storagea field for
// field, so the difference between the two is the mint and nothing else.
//
// The question it answers: nsdata already supports registering a name
// with mintNFT=false and promoting it later via PromoteToNFTRecord. If
// the token is a large share of the per-name cost, deferring it is a
// real saving on every registration that never gets promoted.
package storaged

import (
	"time"

	"gno.land/p/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/grc721"
	"gno.land/p/nt/avl/v0"
)

type Rec struct {
	label      string
	owner      address
	registered time.Time
	expires    time.Time
	streak     int64
	frozen     bool
	isNFT      bool
	extra      avl.Tree
}

var (
	recs avl.Tree
	nft  *grc721.BasicNFT
)

func init(cur realm) {
	nft = grc721.NewBasicNFT(0, cur, "Storage Test", "ST")
}

func Add(cur realm, key string) {
	now := time.Now()
	owner := cur.Previous().Address()
	recs.Set(key, &Rec{
		label:      key,
		owner:      owner,
		registered: now,
		expires:    now.Add(365 * 24 * time.Hour),
		streak:     0,
		frozen:     false,
		isNFT:      true,
		extra:      avl.Tree{},
	})
	// the one difference from storagea
	if err := nft.Mint(owner, grc721.TokenID(key)); err != nil {
		panic(err)
	}
}

func Count() int { return recs.Size() }
