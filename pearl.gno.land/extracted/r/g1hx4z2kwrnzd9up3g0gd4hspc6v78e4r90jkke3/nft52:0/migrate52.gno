// Opt-in, owner-signed migration from the v5.1 factory (nft51) into this
// realm.
//
// WHY THIS FILE EXISTS
//
// gno.land realms are immutable, so every fix ships as a new pkgpath. That
// is good for trust (nobody, including us, can rewrite a live contract) but
// it means a new version starts with an empty ledger. v5.1 was deployed
// WITHOUT any migration entry point, so the tokens minted under v4/v5/v5.1
// can never move into it: an immutable realm cannot grow a door after the
// fact. The door has to exist in the NEW realm at deploy time, which is
// exactly what this file is.
//
// DESIGN RULES
//
//  1. No admin. There is no key, no pause, no operator. A collection is
//     re-registered by its own creator (verified against nft51's stored
//     creator address) and each token is claimed by its own current owner.
//  2. A token can never exist twice. ClaimMigrated pulls the old token into
//     this realm and burns it in the SAME transaction before minting the
//     replacement, so total supply across both realms is conserved and
//     nobody can sell the v5.1 copy of an already-migrated token.
//  3. Identity is preserved. The replacement keeps the original token ID,
//     seed (generative) or URI + traits (stored), royalty percentage and
//     creator, so artwork and provenance survive byte-identically.
//  4. Migration is optional and unlimited in time. The old realm keeps
//     working forever; a holder who never claims loses nothing.
//  5. Nothing is minted for free. The claim mints into the new collection's
//     reserved ID range (nextTokenID starts past the old collection's
//     lifetime mints), so a migration can never consume a slot that a new
//     mint would have had, and vice versa.
package nft52

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/tokens/grc721"
	"gno.land/p/nt/avl/v0"

	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft51"
)

// SourceRealm is the single realm this one accepts migrations from. It is a
// const, so the accepted source can never be repointed at a realm the
// holders did not agree to.
const SourceRealm = "gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft51"

var (
	// migratedTo maps an nft51 collection ID -> this realm's collection ID.
	migratedTo = avl.NewTree()
	// migratedFrom is the reverse map, for the UI's "migrated from v5.1"
	// badge and for auditors.
	migratedFrom = avl.NewTree()
	// claimedFrom marks "oldCollectionID:tokenID" as already claimed.
	claimedFrom = avl.NewTree()
)

// MigrateCollection re-registers an nft51 collection in this realm and
// returns the new collection ID. Only the original creator can call it, and
// only once per source collection. It mints nothing: holders claim their own
// tokens afterwards with ClaimMigrated.
func MigrateCollection(cur realm, oldCollectionID string) string {
	caller := callerOf(cur)

	if _, ok := migratedTo.Get(oldCollectionID).(string); ok {
		panic("this collection has already been migrated")
	}

	info := nft51.GetCollection(oldCollectionID)
	if caller != info.Creator {
		panic("only the original collection's creator can migrate it")
	}

	collCount++
	id := strconv.FormatInt(collCount, 10)

	c := &Collection{
		id:          id,
		name:        info.Name,
		symbol:      info.Symbol,
		description: info.Description,
		baseURI:     info.BaseURI,
		creator:     info.Creator,
		maxSupply:   info.MaxSupply,
		publicMint:  info.PublicMint,
		royaltyPct:  info.RoyaltyPct,
		token:       grc721.NewNFTWithRoyalty(0, cur, info.Name, info.Symbol),
		// Reserve the old ID range: claims land on their original IDs and
		// fresh mints continue after the last ID the old realm ever issued.
		nextTokenID:  info.MintedTotal + 1,
		maxPerWallet: info.MaxPerWallet,
		mintedBy:     avl.NewTree(),
		generative:   info.Generative,
		engine:       info.Engine,
		createdAt:    runtime.ChainHeight(),
	}
	collections.Set(id, c)
	collectionsByCreator.Set(info.Creator.String()+":"+id, id)
	migratedTo.Set(oldCollectionID, id)
	migratedFrom.Set(id, oldCollectionID)

	chain.Emit(
		"CollectionMigrated",
		"source", SourceRealm,
		"oldCollection", oldCollectionID,
		"id", id,
		"creator", info.Creator.String(),
	)

	return id
}

// ClaimMigrated moves one token from nft51 into this realm, keeping its ID,
// artwork and traits. The caller must currently own the token in nft51 and
// must first approve THIS realm's address on it (nft51.Approve or
// nft51.SetApprovalForAll) — the same approve-then-act flow the marketplace
// uses, so no extra trust is introduced. The old token is burned in this
// same transaction.
func ClaimMigrated(cur realm, oldCollectionID, tokenID string) string {
	caller := callerOf(cur)
	self := cur.Address()

	newID, ok := migratedTo.Get(oldCollectionID).(string)
	if !ok {
		panic("this collection has not been migrated yet; its creator must call MigrateCollection first")
	}
	claimKey := oldCollectionID + ":" + tokenID
	if _, done := claimedFrom.Get(claimKey).(string); done {
		panic("this token has already been claimed")
	}

	owner, err := nft51.OwnerOf(oldCollectionID, tokenID)
	if err != nil {
		panic(err)
	}
	if owner != caller {
		panic("only the token's current owner can claim it")
	}
	approved, _ := nft51.GetApproved(oldCollectionID, tokenID)
	if approved != self && !nft51.IsApprovedForAll(oldCollectionID, owner, self) {
		panic("this realm is not approved to move your v5.1 token yet; call nft51.Approve or nft51.SetApprovalForAll first")
	}

	// Copy everything that defines the token BEFORE destroying it.
	seed := nft51.TokenSeed(oldCollectionID, tokenID)
	uri := ""
	var attrs []Attribute
	if seed == "" {
		if u, err := nft51.TokenURI(oldCollectionID, tokenID); err == nil {
			uri = u
		}
		for _, a := range nft51.TokenAttributes(oldCollectionID, tokenID) {
			attrs = append(attrs, Attribute{TraitType: a.TraitType, Value: a.Value})
		}
	}

	// Rule 2: one token, one realm. Pull it in, then burn it, then mint the
	// replacement. If any step panics the whole transaction reverts, so the
	// holder can never end up with zero tokens either.
	nft51.TransferFrom(cross(cur), oldCollectionID, tokenID, caller, self)
	nft51.Burn(cross(cur), oldCollectionID, tokenID)

	c := mustGetCollection(newID)
	tid := grc721.TokenID(tokenID)
	if err := c.token.Mint(caller, tid); err != nil {
		panic(err)
	}
	if uri != "" {
		if _, err := c.token.SetTokenURI(caller, tid, grc721.TokenURI(uri)); err != nil {
			panic(err)
		}
	}
	if c.royaltyPct > 0 {
		if err := c.token.SetTokenRoyalty(caller, tid, grc721.RoyaltyInfo{
			PaymentAddress: c.creator,
			Percentage:     c.royaltyPct,
		}); err != nil {
			panic(err)
		}
	}

	c.mintedTotal++
	ownerIndex.Set(caller.String()+":"+newID+":"+tokenID, true)
	collectionTokens.Set(newID+":"+padID(tokenID), tokenID)
	if seed != "" {
		seeds.Set(newID+":"+tokenID, seed)
		if !strings.HasPrefix(c.baseURI, "data:") {
			c.onchainTokens++
		}
	} else {
		if len(attrs) > 0 {
			attributes.Set(newID+":"+tokenID, attrs)
		}
		effURI := uri
		if effURI == "" {
			effURI = c.baseURI
		}
		if strings.HasPrefix(effURI, "data:") {
			c.onchainTokens++
		} else if strings.HasPrefix(effURI, "ipfs://") {
			c.ipfsTokens++
		}
	}
	claimedFrom.Set(claimKey, newID+":"+tokenID)

	chain.Emit(
		"TokenMigrated",
		"source", SourceRealm,
		"oldCollection", oldCollectionID,
		"collection", newID,
		"tokenId", tokenID,
		"owner", caller.String(),
	)

	return tokenID
}

// Read-only migration views.

// MigratedCollectionOf returns this realm's collection ID for an nft51
// collection, or "" when it has not been migrated.
func MigratedCollectionOf(oldCollectionID string) string {
	id, _ := migratedTo.Get(oldCollectionID).(string)
	return id
}

// SourceCollectionOf returns the nft51 collection a collection in this realm
// was migrated from, or "" when it was created here.
func SourceCollectionOf(collectionID string) string {
	old, _ := migratedFrom.Get(collectionID).(string)
	return old
}

// ClaimedAs returns "collectionId:tokenId" in this realm for an already
// claimed nft51 token, or "" when it has not been claimed.
func ClaimedAs(oldCollectionID, tokenID string) string {
	ref, _ := claimedFrom.Get(oldCollectionID + ":" + tokenID).(string)
	return ref
}
