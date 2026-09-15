// Package stable is the permanent, never-redeployed half of the Gems
// split-realm design: it holds GRC721 ownership + metadata storage,
// mint pricing, and the per-wallet whitelist, and gates minting to
// whichever ONE "version" realm the owner currently approves. Mint
// MECHANICS (trait assembly, art rendering) live in that version realm
// instead -- e.g. gems2/v1 -- and can be redeployed and re-approved at
// will, with zero holder migration, because ownership never moved.
//
// This mirrors the mechanism already proven on Pearl in the throwaway
// splitpoc spike (see gems-owner's own splitpoc/stable.gno): same
// approvedVersion gate, same cur.Previous().PkgPath() caller check
// (confirmed working on-chain there). Pricing and the whitelist live
// HERE rather than in the version realm specifically so a future
// mint-logic redeploy can never silently change what someone owes, or
// lose whitelist entries that took real work to compile (see
// conversation history, 2026-09-14, for the Tardigrade/baby-Tardigrade
// snapshot this was built for).
//
// Redeployed once already (the very first stable had no way to LIST the
// whitelist, only look up one wallet at a time -- WhitelistCount/
// WhitelistEntry below fix that). Also: storage-deposit funding for
// every write here is paid by whoever CALLS the mint, not by this
// realm's own account (confirmed live, 2026-09-14, after mis-funding
// this realm's derived address for no reason) -- nothing here needs to
// hold a standing balance.
package stable

import (
	unsaferealm "chain/runtime/unsafe"
	"strings"

	"gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/avl"
	grc721 "gno.land/p/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/grc721v2"
)

const (
	CollectionName   = "Gems"
	CollectionSymbol = "GEMS"
)

var (
	nft *grc721.MetadataNFT

	// collectionOwner is the only address allowed to change pricing,
	// the whitelist, or which version realm is approved.
	collectionOwner address = "g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku"

	// approvedVersion is the full pkgpath of the ONE realm currently
	// allowed to call RecordMint. Empty until the owner sets it via
	// SetApprovedVersion -- RecordMint refuses to mint until then.
	approvedVersion string

	// mintPriceUgnot is the standard price a non-whitelisted wallet
	// pays. Owner-adjustable at any time; does not affect any token
	// already minted. 0 means free for everyone.
	mintPriceUgnot int64 = 1_000_000

	// whitelistBps holds per-wallet price overrides in basis points of
	// mintPriceUgnot (10000 = full price, 5000 = half, 1000 = pay 10%,
	// 0 = free). A wallet with no entry pays mintPriceUgnot unchanged.
	// Percentage rather than a fixed ugnot amount so a later
	// SetMintPrice change is reflected for everyone on the list
	// automatically, instead of leaving discounts stale against a price
	// that no longer exists.
	whitelistBps avl.Tree

	// mintedIDs is an append-only record of every token minted here, in
	// mint order, regardless of which approved version minted it --
	// grc721's own internal owners map can't be iterated.
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

func BalanceOf(owner address) (int64, error) {
	return nft.BalanceOf(owner)
}

func TokenMetadata(tid grc721.TokenID) (grc721.Metadata, error) {
	return nft.TokenMetadata(tid)
}

func TokenURI(tid grc721.TokenID) (string, error) {
	return nft.TokenURI(tid)
}

func ApprovedVersion() string { return approvedVersion }
func Owner() address           { return collectionOwner }
func MintPrice() int64         { return mintPriceUgnot }

func MintedIDs() []grc721.TokenID { return mintedIDs }

// WhitelistBps reports wallet's current price override in basis points,
// and whether it has one at all (ok == false means: pays full price).
func WhitelistBps(wallet address) (bps int64, ok bool) {
	if !whitelistBps.Has(wallet.String()) {
		return 0, false
	}
	return whitelistBps.Get(wallet.String()).(int64), true
}

// WhitelistCount and WhitelistEntry let a panel page through every
// current whitelist entry -- avl.Tree supports index-based access
// (Size/GetByIndex) even though it has no built-in "list everything"
// call, so this is a thin wrapper over that rather than new storage.
// Added in this redeploy specifically because the first stable had no
// way to answer "who's on the whitelist right now" short of a
// single-address lookup (see conversation history, 2026-09-14).
func WhitelistCount() int64 { return int64(whitelistBps.Size()) }

func WhitelistEntry(index int) (wallet string, bps int64) {
	w, v := whitelistBps.GetByIndex(index)
	return w, v.(int64)
}

// EffectivePrice returns what caller actually owes for a mint right
// now: their whitelist-adjusted price if they have one, otherwise the
// standard mintPriceUgnot. Called by the approved version realm's own
// MintAssembled -- a plain cross-realm READ, no `cur` needed.
func EffectivePrice(caller address) int64 {
	if whitelistBps.Has(caller.String()) {
		return mintPriceUgnot * whitelistBps.Get(caller.String()).(int64) / 10000
	}
	return mintPriceUgnot
}

/* -------------------------------- owner-gated -------------------------------- */

// callerAddress mirrors nftminter.gno's own helper exactly.
func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func assertOwner() {
	if callerAddress() != collectionOwner {
		panic("unauthorized: caller is not the collection owner")
	}
}

// SetApprovedVersion is THE single point of trust in this whole design.
// Owner-only. Whatever pkgpath is set here becomes the only realm
// allowed to call RecordMint -- flipping it is how a bad version gets
// rolled back, or a fixed one gets promoted, with zero redeploy and zero
// holder migration.
func SetApprovedVersion(cur realm, pkgpath string) {
	assertOwner()
	approvedVersion = pkgpath
}

// SetMintPrice updates the standard price. Owner-only. Does not affect
// any token already minted, or any wallet's whitelist override (those
// stay relative -- see EffectivePrice).
func SetMintPrice(cur realm, ugnot int64) {
	assertOwner()
	if ugnot < 0 {
		panic("price cannot be negative")
	}
	mintPriceUgnot = ugnot
}

// AddToWhitelist sets (or overwrites) wallet's price override, in basis
// points of the CURRENT mintPriceUgnot. 0 = free, 1000 = pay 10%, 5000
// = pay 50%. Owner-only. Takes effect on that wallet's very next mint --
// no redeploy needed, can be changed or revoked at any later time.
func AddToWhitelist(cur realm, wallet address, bps int64) {
	assertOwner()
	if bps < 0 || bps > 10000 {
		panic("bps must be between 0 and 10000")
	}
	whitelistBps.Set(wallet.String(), bps)
}

// AddToWhitelistBatch applies ONE bps value to MANY wallets in a single
// call -- for onboarding a whole tier (e.g. every address in a snapshot
// CSV) without one transaction per wallet. walletsCSV is comma-separated
// bech32 addresses; whitespace around each is trimmed, empty entries
// skipped. Owner-only, same bps validation as AddToWhitelist.
func AddToWhitelistBatch(cur realm, walletsCSV string, bps int64) {
	assertOwner()
	if bps < 0 || bps > 10000 {
		panic("bps must be between 0 and 10000")
	}
	for _, w := range strings.Split(walletsCSV, ",") {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		whitelistBps.Set(w, bps)
	}
}

// RemoveFromWhitelist drops wallet's override -- it falls back to
// paying mintPriceUgnot again. Owner-only.
func RemoveFromWhitelist(cur realm, wallet address) {
	assertOwner()
	whitelistBps.Remove(wallet.String())
}

/* ------------------------------- version-gated -------------------------------- */

// assertCallerIsApprovedVersion -- the security boundary this whole
// design exists for. Uses cur.Previous().PkgPath(), confirmed working
// on Pearl in the splitpoc spike (2026-09-14): approve v1, mint from
// v1, confirm v2 rejected, approve v2, confirm v1 now rejected, switch
// back to v1, confirm it works again -- all four transitions verified
// on-chain, not assumed.
func assertCallerIsApprovedVersion(cur realm) {
	caller := cur.Previous().PkgPath()
	if approvedVersion == "" {
		panic("no version realm has been approved yet")
	}
	if caller != approvedVersion {
		panic("unauthorized: caller is not the approved version realm")
	}
}

// RecordMint is the ONLY way a token gets minted into this realm's
// storage. Only the currently-approved version realm may call it.
// Payment verification happens in the VERSION realm instead (it's the
// direct target of the origin call, so that's where the frame-sensitive
// AssertOriginCall/PreviousRealm checks belong -- see gems2/v1's own
// MintAssembled) -- RecordMint trusts that payment was already verified
// by the time it's called, and only handles the actual mint + storage.
func RecordMint(cur realm, to address, tid grc721.TokenID, metadata grc721.Metadata) grc721.TokenID {
	assertCallerIsApprovedVersion(cur)
	checkErr(nft.Mint(to, tid))
	checkErr(nft.SetTokenMetadata(to, tid, metadata))
	mintedIDs = append(mintedIDs, tid)
	return tid
}

func checkErr(err error) {
	if err != nil {
		panic(err)
	}
}
