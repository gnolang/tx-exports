// Package nftlimits stores an optional "max tokens per wallet" cap for
// collections minted through gno.land/r/hazen/nft, as a separate realm
// for the same reason nftoffers is separate: gno.land packages are
// immutable once deployed, and nft.gno was already live with real
// collections, so there is no in-place way to add a new field to its
// Collection struct or a new check to its Mint function.
//
// IMPORTANT — this is an advisory / frontend-enforced cap, not a
// trustless one. nft.Mint itself has no knowledge of this realm and
// does not consult it, so nothing on-chain stops a caller from
// bypassing the limit by calling nft.Mint directly (e.g. via gnokey)
// instead of going through the gnoNFT frontend. True trustless
// enforcement would require the check to live inside nft.gno's own
// Mint function, which can't be retrofitted onto the already-deployed
// realm. This is still useful for the normal case (everyone mints
// through the dApp UI) and is the best available option without
// forking the whole nft/nftmarket/nftoffers realm family onto a new,
// mutually-incompatible v2 path.
package nftlimits

import (
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft"
)

// limits maps collectionID -> int64 (max tokens per wallet). Absence
// from the tree means "no limit configured" (unlimited), same
// convention nft.gno uses for maxSupply/publicMint.
var limits = avl.NewTree()

// SetMaxPerWallet sets (or clears, with max == 0) the per-wallet mint
// cap for a collection. Only the collection's creator (per
// nft.GetCollection) may call this.
func SetMaxPerWallet(cur realm, collectionID string, max int64) {
	caller := unsafe.OriginCaller()

	c := nft.GetCollection(collectionID) // panics if the collection doesn't exist
	if c.Creator != caller {
		panic("only the collection's creator can set its mint limit")
	}
	if max < 0 {
		panic("max must be >= 0 (0 clears the limit)")
	}

	if max == 0 {
		limits.Remove(collectionID)
		return
	}
	limits.Set(collectionID, max)
}

// GetMaxPerWallet returns the configured per-wallet cap for a
// collection, or 0 if none is set (unlimited).
func GetMaxPerWallet(collectionID string) int64 {
	v := limits.Get(collectionID)
	if v == nil {
		return 0
	}
	return v.(int64)
}

// Render implements the gno.land realm home-page convention.
func Render(path string) string {
	if path != "" {
		max := GetMaxPerWallet(path)
		if max == 0 {
			return "# collection " + path + "\n\nno per-wallet mint limit configured.\n"
		}
		return "# collection " + path + "\n\nmax " + strconv.FormatInt(max, 10) + " token(s) per wallet.\n"
	}

	out := "# Hazen NFT Mint Limits\n\n"
	hasAny := false
	limits.Iterate("", "", func(key string, value any) bool {
		hasAny = true
		out += "- collection " + key + ": max " + strconv.FormatInt(value.(int64), 10) + " per wallet\n"
		return false
	})
	if !hasAny {
		out += "No collections have a configured mint limit.\n"
	}
	return out
}
