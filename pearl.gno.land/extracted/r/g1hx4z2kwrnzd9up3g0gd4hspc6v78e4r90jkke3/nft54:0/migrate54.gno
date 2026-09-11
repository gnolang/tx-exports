// Hardened, multi-source, batch-capable migration into this realm.
//
// WHAT V5.3 ADDS OVER V5.2's migrate52.gno
//
//  1. TWO accepted sources instead of one (nft52 AND nft53), so a holder who
//     skipped a version never has to claim twice through an intermediate
//     realm. Both are consts: the accepted set can never be repointed, and a
//     future realm that accepts more sources is a different pkgpath the user
//     explicitly opts into.
//  2. Batch claiming. ClaimMigratedBatch takes a comma-separated token list
//     (vm.MsgCall only carries scalar strings) and claims up to
//     MaxClaimBatch tokens in one transaction, so a wallet holding N tokens
//     pays one fixed transaction cost instead of N.
//  3. Claim marker is written BEFORE the cross-realm calls. Even if a future
//     source realm were re-entrant, a token can never be claimed twice.
//  4. Permissionless collection registration. In v5.3 only the original
//     creator could register a collection, so an absent creator could strand
//     their holders. Here ANY holder of a token in the source collection can
//     register it - which is safe because every field (name, symbol,
//     description, baseURI, creator, maxSupply, royalty, generative, engine)
//     is copied verbatim from the source realm's own state. A stranger
//     registering the collection cannot alter one byte of it, cannot become
//     its creator, and cannot redirect its royalties.
//  5. Approval hygiene helpers. SourceApprovalOf lets the UI show, and nag
//     about, a still-open SetApprovalForAll after a batch claim. A realm
//     cannot revoke a user's approval on the user's behalf (that signature
//     belongs to the owner), so the safe pattern is surfaced instead of
//     silently left open.
//
// STILL TRUE, BY DESIGN: no admin, no pause, no proxy, no key. A collection
// is registered from chain-derived data only, a token is moved only by its
// own current owner, the old token is burned in the same transaction, and
// nobody is ever forced to migrate.
package nft54

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/tokens/grc721"
	"gno.land/p/nt/avl/v0"

	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft52"
	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft53"
)

// Accepted source realms. Callers pass the short label; the pkgpath consts
// exist so the label can be resolved to an auditable path in views.
const (
	SourceV52 = "v5.2"
	SourceV53 = "v5.3"

	SourceRealmV52 = "gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft52"
	SourceRealmV53 = "gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nft53"

	// MaxClaimBatch bounds one batch so a caller cannot build a transaction
	// that is guaranteed to run out of gas after doing partial work. The
	// whole batch is one transaction: it either all applies or all reverts.
	MaxClaimBatch = 25
)

var (
	// migratedTo maps "source:oldCollectionID" -> this realm's collection ID.
	migratedTo = avl.NewTree()
	// migratedFrom is the reverse map for the "migrated from" badge.
	migratedFrom = avl.NewTree()
	// claimedFrom marks "source:oldCollectionID:tokenID" as claimed.
	claimedFrom = avl.NewTree()
)

// srcCollection is the source-realm-agnostic view of a collection, so the
// migration logic is written once for both accepted sources.
type srcCollection struct {
	name        string
	symbol      string
	description string
	baseURI     string
	creator     address
	maxSupply   int64
	mintedTotal int64
	royaltyPct  int64
	maxPerWallet int64
	publicMint  bool
	generative  bool
	engine      string
}

func assertSource(source string) {
	if source != SourceV52 && source != SourceV53 {
		panic("unknown source realm; use \"" + SourceV52 + "\" or \"" + SourceV53 + "\"")
	}
}

// SourceRealmPath resolves a source label to the pkgpath it will act on, so
// a caller can verify what they are about to touch before signing.
func SourceRealmPath(source string) string {
	assertSource(source)
	if source == SourceV52 {
		return SourceRealmV52
	}
	return SourceRealmV53
}

func srcGetCollection(source, collectionID string) srcCollection {
	assertSource(source)
	if source == SourceV52 {
		i := nft52.GetCollection(collectionID)
		return srcCollection{
			name: i.Name, symbol: i.Symbol, description: i.Description,
			baseURI: i.BaseURI, creator: i.Creator, maxSupply: i.MaxSupply,
			mintedTotal: i.MintedTotal, royaltyPct: i.RoyaltyPct,
			maxPerWallet: i.MaxPerWallet, publicMint: i.PublicMint,
			generative: i.Generative, engine: i.Engine,
		}
	}
	i := nft53.GetCollection(collectionID)
	return srcCollection{
		name: i.Name, symbol: i.Symbol, description: i.Description,
		baseURI: i.BaseURI, creator: i.Creator, maxSupply: i.MaxSupply,
		mintedTotal: i.MintedTotal, royaltyPct: i.RoyaltyPct,
		maxPerWallet: i.MaxPerWallet, publicMint: i.PublicMint,
		generative: i.Generative, engine: i.Engine,
	}
}

func srcOwnerOf(source, collectionID, tokenID string) address {
	assertSource(source)
	if source == SourceV52 {
		owner, err := nft52.OwnerOf(collectionID, tokenID)
		if err != nil {
			panic(err)
		}
		return owner
	}
	owner, err := nft53.OwnerOf(collectionID, tokenID)
	if err != nil {
		panic(err)
	}
	return owner
}

func srcIsApproved(source, collectionID, tokenID string, owner, spender address) bool {
	assertSource(source)
	if source == SourceV52 {
		approved, _ := nft52.GetApproved(collectionID, tokenID)
		return approved == spender || nft52.IsApprovedForAll(collectionID, owner, spender)
	}
	approved, _ := nft53.GetApproved(collectionID, tokenID)
	return approved == spender || nft53.IsApprovedForAll(collectionID, owner, spender)
}

func srcSeed(source, collectionID, tokenID string) string {
	assertSource(source)
	if source == SourceV52 {
		return nft52.TokenSeed(collectionID, tokenID)
	}
	return nft53.TokenSeed(collectionID, tokenID)
}

func srcTokenURI(source, collectionID, tokenID string) string {
	assertSource(source)
	if source == SourceV52 {
		if u, err := nft52.TokenURI(collectionID, tokenID); err == nil {
			return u
		}
		return ""
	}
	if u, err := nft53.TokenURI(collectionID, tokenID); err == nil {
		return u
	}
	return ""
}

func srcAttributes(source, collectionID, tokenID string) []Attribute {
	assertSource(source)
	var out []Attribute
	if source == SourceV52 {
		for _, a := range nft52.TokenAttributes(collectionID, tokenID) {
			out = append(out, Attribute{TraitType: a.TraitType, Value: a.Value})
		}
		return out
	}
	for _, a := range nft53.TokenAttributes(collectionID, tokenID) {
		out = append(out, Attribute{TraitType: a.TraitType, Value: a.Value})
	}
	return out
}

// srcPullAndBurn moves the source token to this realm and destroys it. Both
// steps happen inside the caller's transaction, so the token can never be
// alive in two realms at once.
func srcPullAndBurn(cur realm, source, collectionID, tokenID string, from, to address) {
	assertSource(source)
	if source == SourceV52 {
		nft52.TransferFrom(cross(cur), collectionID, tokenID, from, to)
		nft52.Burn(cross(cur), collectionID, tokenID)
		return
	}
	nft53.TransferFrom(cross(cur), collectionID, tokenID, from, to)
	nft53.Burn(cross(cur), collectionID, tokenID)
}

// SourceApprovalOf reports whether `spender` may currently move one source
// token. The UI uses it with this realm's own address to nag the user into
// revoking a blanket SetApprovalForAll once their migration is finished: a
// realm cannot revoke an approval the owner signed, so the honest move is to
// make the leftover permission visible.
func SourceApprovalOf(source, collectionID, tokenID string, owner, spender address) bool {
	return srcIsApproved(source, collectionID, tokenID, owner, spender)
}

// MigrateCollection registers a source collection in this realm and returns
// the new collection ID.
//
// Callable by the original creator OR by any current holder of a token in
// that source collection. That is deliberately permissionless: every field
// is copied from the source realm's own state, including the creator address
// and the royalty percentage, so whoever pays the registration fee cannot
// change the collection, cannot claim its creator seat and cannot redirect
// its royalties. It only removes the risk of an inactive creator stranding
// their holders.
//
// proofTokenID is how a non-creator proves that holding (nft54.gno
// package doc, v5.4 change 4). v5.3 proved the same thing by scanning OwnerOf over the
// source collection's entire lifetime supply, one cross-realm call per
// token: correct, but the gas cost grew with the collection, so a large
// collection could become impossible to register at all. Now the caller
// names ONE token they own and the realm checks that single token, so the
// cost is the same for a 10-token and a 10,000-token collection.
//
// This is not a weaker check. The realm still verifies ownership itself
// against the source realm's live state; naming a token you do not own
// fails. The creator path ignores proofTokenID entirely and may pass "".
func MigrateCollection(cur realm, source, oldCollectionID, proofTokenID string) string {
	caller := callerOf(cur)
	assertSource(source)

	key := source + ":" + oldCollectionID
	if _, ok := migratedTo.Get(key).(string); ok {
		panic("this collection has already been migrated")
	}

	info := srcGetCollection(source, oldCollectionID)
	if caller != info.creator {
		proof := strings.TrimSpace(proofTokenID)
		if proof == "" {
			panic("only the collection's creator can migrate it without proof; " +
				"pass the ID of a token you own in that collection as proofTokenID")
		}
		if ownerOfOrEmpty(source, oldCollectionID, proof) != caller {
			panic("you do not own token " + proof + " in that source collection")
		}
	}

	collCount++
	id := strconv.FormatInt(collCount, 10)

	c := &Collection{
		id:          id,
		name:        info.name,
		symbol:      info.symbol,
		description: info.description,
		baseURI:     info.baseURI,
		// The ORIGINAL creator, never the caller: royalties and creator-only
		// powers stay exactly where they were.
		creator:    info.creator,
		maxSupply:  info.maxSupply,
		publicMint: info.publicMint,
		royaltyPct: info.royaltyPct,
		token:      grc721.NewNFTWithRoyalty(0, cur, info.name, info.symbol),
		// Reserve the source's ID range so a claim and a fresh mint can never
		// compete for the same token ID.
		nextTokenID:  info.mintedTotal + 1,
		maxPerWallet: info.maxPerWallet,
		mintedBy:     avl.NewTree(),
		generative:   info.generative,
		engine:       info.engine,
		createdAt:    runtime.ChainHeight(),
	}
	collections.Set(id, c)
	collectionsByCreator.Set(info.creator.String()+":"+id, id)
	migratedTo.Set(key, id)
	migratedFrom.Set(id, key)

	chain.Emit(
		"CollectionMigrated",
		"source", SourceRealmPath(source),
		"oldCollection", oldCollectionID,
		"id", id,
		"creator", info.creator.String(),
		"registeredBy", caller.String(),
	)

	return id
}

// ownerOfOrEmpty is srcOwnerOf without the panic, for burned/missing tokens.
func ownerOfOrEmpty(source, collectionID, tokenID string) address {
	if source == SourceV52 {
		owner, err := nft52.OwnerOf(collectionID, tokenID)
		if err != nil {
			return address("")
		}
		return owner
	}
	owner, err := nft53.OwnerOf(collectionID, tokenID)
	if err != nil {
		return address("")
	}
	return owner
}

// ClaimMigrated moves one token from an accepted source realm into this one,
// keeping its ID, seed or URI, traits, royalty and creator. The caller must
// own the token in the source realm and must have approved THIS realm's
// address there first.
func ClaimMigrated(cur realm, source, oldCollectionID, tokenID string) string {
	return claimOne(cur, source, oldCollectionID, strings.TrimSpace(tokenID), callerOf(cur), cur.Address())
}

// ClaimMigratedBatch claims several tokens of one source collection in a
// single transaction. tokenIDs is a comma-separated list ("1,2,7") because
// vm.MsgCall only carries scalar strings. Up to MaxClaimBatch entries; the
// batch is atomic, so one bad entry reverts the whole call and nothing is
// half-migrated.
func ClaimMigratedBatch(cur realm, source, oldCollectionID, tokenIDs string) int64 {
	caller := callerOf(cur)
	self := cur.Address()

	parts := strings.Split(tokenIDs, ",")
	if len(parts) == 0 {
		panic("tokenIDs must not be empty")
	}
	if len(parts) > MaxClaimBatch {
		panic("too many tokens in one batch (max " + strconv.Itoa(MaxClaimBatch) + "); split the claim")
	}

	var n int64
	for _, raw := range parts {
		tokenID := strings.TrimSpace(raw)
		if tokenID == "" {
			panic("tokenIDs contains an empty entry")
		}
		claimOne(cur, source, oldCollectionID, tokenID, caller, self)
		n++
	}

	chain.Emit(
		"BatchMigrated",
		"source", SourceRealmPath(source),
		"oldCollection", oldCollectionID,
		"count", strconv.FormatInt(n, 10),
		"owner", caller.String(),
	)

	return n
}

func claimOne(cur realm, source, oldCollectionID, tokenID string, caller, self address) string {
	assertSource(source)

	newID, ok := migratedTo.Get(source + ":" + oldCollectionID).(string)
	if !ok {
		panic("this collection has not been migrated yet; call MigrateCollection first")
	}
	claimKey := source + ":" + oldCollectionID + ":" + tokenID
	if _, done := claimedFrom.Get(claimKey).(string); done {
		panic("this token has already been claimed")
	}

	owner := srcOwnerOf(source, oldCollectionID, tokenID)
	if owner != caller {
		panic("only the token's current owner can claim it")
	}
	if !srcIsApproved(source, oldCollectionID, tokenID, owner, self) {
		panic("this realm is not approved to move that token yet; approve it in the source realm first")
	}

	// Copy everything that defines the token before destroying it.
	seed := srcSeed(source, oldCollectionID, tokenID)
	uri := ""
	var attrs []Attribute
	if seed == "" {
		uri = srcTokenURI(source, oldCollectionID, tokenID)
		attrs = srcAttributes(source, oldCollectionID, tokenID)
	}

	// Mark the claim BEFORE any cross-realm call: a re-entrant source realm
	// must not be able to walk back into claimOne for the same token.
	claimedFrom.Set(claimKey, newID+":"+tokenID)

	srcPullAndBurn(cur, source, oldCollectionID, tokenID, caller, self)

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
	c.mintedTotal++
	ownerIndex.Set(caller.String()+":"+newID+":"+tokenID, true)
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

	chain.Emit(
		"TokenMigrated",
		"source", SourceRealmPath(source),
		"oldCollection", oldCollectionID,
		"collection", newID,
		"tokenId", tokenID,
		"owner", caller.String(),
	)

	return tokenID
}

// Read-only migration views.

// MigratedCollectionOf returns this realm's collection ID for a source
// collection, or "" when it has not been migrated.
func MigratedCollectionOf(source, oldCollectionID string) string {
	id, _ := migratedTo.Get(source + ":" + oldCollectionID).(string)
	return id
}

// SourceCollectionOf returns "source:oldCollectionID" for a collection that
// arrived by migration, or "" when it was created here.
func SourceCollectionOf(collectionID string) string {
	old, _ := migratedFrom.Get(collectionID).(string)
	return old
}

// ClaimedAs returns "collectionId:tokenId" in this realm for an already
// claimed source token, or "" when it has not been claimed.
func ClaimedAs(source, oldCollectionID, tokenID string) string {
	ref, _ := claimedFrom.Get(source + ":" + oldCollectionID + ":" + tokenID).(string)
	return ref
}
