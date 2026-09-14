// Package stable is a throwaway testnet spike, NOT a Gems deploy and
// not themed after it beyond proving the same idea. It exists purely
// to validate one mechanism before it's ever used for real: a
// permanent, never-redeployed realm that holds GRC721 ownership state
// and lets only ONE specific, owner-approved "version" realm write to
// it.
//
// Why: every one of the real collection's g17->g18->g19->g20 jumps
// forced a full 81-token holder migration for what was really just a
// mint-logic bug (a wrong realmRelPath constant, a wrong trait lookup
// path) -- none of those bugs had anything to do with who owned what.
// If ownership storage had lived here instead of inside the
// redeployed realm each time, none of those migrations would have
// been necessary. This spike proves the split works -- specifically,
// that the version-gate in RecordMint actually holds -- before it's
// applied to a real collection ahead of mainnet. See conversation
// history (2026-09-14) for the full design discussion.
package stable

import (
	unsaferealm "chain/runtime/unsafe"

	// Aliased to grc721, matching nftminter/g20's own import (grc721v2 is
	// literally the package's declared name; the alias is just so every
	// grc721.X reference below reads the same as the real collection's).
	grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
)

const (
	CollectionName   = "SplitPoc"
	CollectionSymbol = "SPLITPOC"
)

var (
	nft *grc721.MetadataNFT

	// collectionOwner is the only address allowed to change which
	// version realm is approved to write. Same address/pattern as the
	// real nftminter's own collectionOwner -- reusing it here only
	// because it's already funded and CLA-signed for this spike's
	// deploy, not because this realm is part of that collection.
	collectionOwner address = "g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems"

	// approvedVersion is the full pkgpath of the ONE realm currently
	// allowed to call RecordMint. Empty until the owner sets it via
	// SetApprovedVersion -- RecordMint refuses to mint until then.
	approvedVersion string

	// mintedIDs is an append-only record of every token minted here,
	// in mint order -- same "can't iterate grc721's internal owners
	// map" reason the real nftminter keeps its own copy.
	mintedIDs []grc721.TokenID
)

func init(cur realm) {
	nft = grc721.NewNFTWithMetadata(0, cur, CollectionName, CollectionSymbol)
}

/* ------------------------------ standard reads ------------------------------ */

func Name() string      { return CollectionName }
func Symbol() string    { return CollectionSymbol }
func TokenCount() int64 { return nft.TokenCount() }

func OwnerOf(tid grc721.TokenID) (address, error) {
	return nft.OwnerOf(tid)
}

func TokenMetadata(tid grc721.TokenID) (grc721.Metadata, error) {
	return nft.TokenMetadata(tid)
}

// ApprovedVersion reports the pkgpath currently allowed to call
// RecordMint -- "" if the owner hasn't approved one yet.
func ApprovedVersion() string {
	return approvedVersion
}

func Owner() address {
	return collectionOwner
}

// MintedIDs lists every token minted here, in mint order, regardless
// of which approved version minted it -- this is exactly the
// cross-version continuity this whole design exists to get.
func MintedIDs() []grc721.TokenID {
	return mintedIDs
}

/* -------------------------------- owner-gated -------------------------------- */

// callerAddress mirrors nftminter.gno's own helper exactly (same
// reasoning: this realm's exported entrypoints are each the sole
// crossing frame in their call chain, so unsaferealm.PreviousRealm()
// can't misidentify the caller here). See that file's doc comment on
// callerAddress if revisiting.
func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func assertOwner() {
	if callerAddress() != collectionOwner {
		panic("unauthorized: caller is not the collection owner")
	}
}

// SetApprovedVersion is THE single point of trust in this whole
// design. Owner-only. Whatever pkgpath is set here becomes the only
// realm allowed to call RecordMint -- flipping it is how a bad version
// gets rolled back, or a fixed one gets promoted, with zero redeploy
// and zero holder migration. Keep this function, and this whole file,
// small: it can never be patched once real holders depend on it.
func SetApprovedVersion(cur realm, pkgpath string) {
	assertOwner()
	approvedVersion = pkgpath
}

/* ------------------------------- version-gated -------------------------------- */

// assertCallerIsApprovedVersion is the actual security boundary this
// spike exists to prove. Two candidate mechanisms, in preference
// order -- and they disagree with each other, which is exactly why
// this needs proving on-chain before it's trusted with real holders:
//
//  1. cur.Previous().PkgPath() -- statically scoped to this exact
//     crossing call. chain/runtime/unsafe's own doc comment calls
//     this "the idiomatic substitute... which is statically scoped to
//     a crossing function and cannot lie." That's the stdlib's own
//     recommendation as of the local gno-src checkout (2026-09).
//  2. unsaferealm.PreviousRealm().PkgPath() -- what nftminter/g20
//     uses today instead for its own caller checks, because ITS doc
//     comment claims cur.Previous() "isn't available on every
//     gno.land network -- confirmed missing on Beta Mainnet's GnoVM
//     as of 2026-08."
//
// This function starts with option 1, per the stdlib's own guidance.
// First real test on Pearl: confirm it actually compiles and resolves
// correctly when v1/v2 call RecordMint. If it turns out unavailable
// here, swap to the commented fallback -- that's a one-line change,
// not a design change.
func assertCallerIsApprovedVersion(cur realm) {
	caller := cur.Previous().PkgPath()
	// Fallback if cur.Previous() turns out unavailable on this chain:
	// caller := unsaferealm.PreviousRealm().PkgPath()

	if approvedVersion == "" {
		panic("no version realm has been approved yet")
	}
	if caller != approvedVersion {
		panic("unauthorized: caller is not the approved version realm")
	}
}

// RecordMint is the ONLY way a token gets minted into this realm's
// storage. Only the currently-approved version realm may call it --
// see assertCallerIsApprovedVersion. Deliberately minimal for this
// spike (no metadata/provenance/reveal): the one thing being proven
// here is that the gate holds, not the full mint flow.
func RecordMint(cur realm, to address, tid grc721.TokenID) {
	assertCallerIsApprovedVersion(cur)
	checkErr(nft.Mint(to, tid))
	mintedIDs = append(mintedIDs, tid)
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
