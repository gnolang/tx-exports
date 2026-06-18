package memba_collections

import (
	"chain"
	"math/overflow"

	"gno.land/p/samcrew/grc721"
)

// SetRoyalty updates the collection-default royalty. Admin only; bps must be
// in [MinCreatorRoyaltyBPS, maxCreatorRoyaltyBPS].
func SetRoyalty(cur realm, id string, recip address, bps int64) {
	c := mustGet(id)
	assertCollectionAdmin(c)
	if bps < MinCreatorRoyaltyBPS || bps > maxCreatorRoyaltyBPS {
		panic("royalty out of range")
	}
	c.royaltyRecip, c.royaltyBPS = recip, bps
	chain.Emit("RoyaltySet", "collectionID", id, "bps", itoa(bps), "recip", recip.String())
}

// SetTokenRoyalty sets a per-token royalty override. PRESENCE of the override
// wins over the collection default — even bps==0 means "royalty OFF for this
// token" (S-1). Admin only; bps <= maxCreatorRoyaltyBPS.
func SetTokenRoyalty(cur realm, id string, tid grc721.TokenID, recip address, bps int64) {
	c := mustGet(id)
	assertCollectionAdmin(c)
	if bps < MinCreatorRoyaltyBPS || bps > maxCreatorRoyaltyBPS {
		panic("royalty out of range")
	}
	c.tokenRoyalty.Set(string(tid), royalty{recip: recip, bps: bps})
	chain.Emit("TokenRoyaltySet", "collectionID", id, "tokenId", string(tid), "bps", itoa(bps), "recip", recip.String())
}

// ClearTokenRoyalty removes a per-token override; the token falls back to the
// collection default. Admin only.
func ClearTokenRoyalty(cur realm, id string, tid grc721.TokenID) {
	c := mustGet(id)
	assertCollectionAdmin(c)
	c.tokenRoyalty.Remove(string(tid))
	chain.Emit("TokenRoyaltyCleared", "collectionID", id, "tokenId", string(tid))
}

// resolveRoyalty returns the effective (recip, bps) for a token, applying the
// frozen precedence: per-token override PRESENCE wins (even bps==0); else the
// collection default.
func resolveRoyalty(c *collection, tid grc721.TokenID) (address, int64) {
	if v, ok := c.tokenRoyalty.Get(string(tid)); ok {
		r := v.(royalty)
		return r.recip, r.bps
	}
	return c.royaltyRecip, c.royaltyBPS
}

// RoyaltyInfo returns the royalty recipient and amount owed on a sale. Returns
// ("", 0) when royalty is disabled for the token (bps==0 or recip==""). This
// is a read; marketplace engines call it to settle royalties atomically.
func RoyaltyInfo(id string, tid grc721.TokenID, salePrice int64) (address, int64) {
	c := mustGet(id)
	recip, bps := resolveRoyalty(c, tid)
	if bps == 0 || recip == "" {
		return "", 0
	}
	return recip, overflow.Mul64p(salePrice, bps) / 10000
}
