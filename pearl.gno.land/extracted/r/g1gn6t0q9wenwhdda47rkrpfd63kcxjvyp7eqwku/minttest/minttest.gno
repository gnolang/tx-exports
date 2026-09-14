// Package minttest is a throwaway Pearl-testnet spike, unrelated to any
// real collection. Its only purpose: measure the real gas/storage cost
// of ONE mint under g20's actual per-token storage shape (owner record +
// a small trait struct + a provenance struct + an ID-list append), while
// skipping everything that shape doesn't need for that measurement (no
// price, no reveal delay, no rendered image -- g20 itself renders SVGs
// fresh on every read rather than storing them, so they don't belong in
// a per-mint storage measurement either). See conversation history
// (2026-09-14) for why this number matters: deciding whether whitelisted
// mainnet wallets should self-mint (they pay real network cost) or the
// owner should mint-and-transfer on their behalf (owner pays, times
// every wallet on the list).
package minttest

import (
	"strconv"

	"gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/avl"
	grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
)

// traitPreset mirrors g20's own traitPreset field-for-field (Chain
// string, ShapeIdx/ColorIdx int, Metal string, Active bool) -- same
// struct shape, so the AVL-stored bytes per token match g20's real
// footprint, not a smaller stand-in.
type traitPreset struct {
	Chain    string
	ShapeIdx int
	ColorIdx int
	Metal    string
	Active   bool
}

// provenanceInfo mirrors g20's own provenanceInfo exactly.
type provenanceInfo struct {
	OriginalChain      string
	OriginalTokenID    string
	OriginalMintHeight int64
}

var (
	nft        *grc721.MetadataNFT
	nextID     int64
	mintedIDs  []grc721.TokenID
	traits     avl.Tree // tid -> traitPreset
	provenance avl.Tree // tid -> provenanceInfo
)

func init(cur realm) {
	nft = grc721.NewNFTWithMetadata(0, cur, "MintTest", "MTEST")
}

// MintTest mints one token with a representative trait+provenance
// payload -- no payment, no reveal delay, no image. Public: the only
// thing this spike measures is the storage/gas cost of the write path.
func MintTest(cur realm, to address) grc721.TokenID {
	tid := grc721.TokenID(strconv.FormatInt(nextID, 10))
	checkErr(nft.Mint(to, tid))

	traits.Set(string(tid), traitPreset{
		Chain:    "TEST-9",
		ShapeIdx: 3,
		ColorIdx: 7,
		Metal:    "Platinum",
		Active:   true,
	})
	provenance.Set(string(tid), provenanceInfo{
		OriginalChain:      "pearl-1",
		OriginalTokenID:    string(tid),
		OriginalMintHeight: 0,
	})
	mintedIDs = append(mintedIDs, tid)
	nextID++
	return tid
}

func TokenCount() int64 { return nft.TokenCount() }
func NextID() int64     { return nextID }

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
