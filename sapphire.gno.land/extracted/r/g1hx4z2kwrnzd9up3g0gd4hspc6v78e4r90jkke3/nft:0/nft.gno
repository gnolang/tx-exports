// Package nft is a multi-tenant GRC-721 NFT factory realm.
//
// Gno.land realms can't be deployed at runtime the way Solidity contracts
// can (every new realm is its own `addpkg` transaction with real source
// code). To still let *anyone* mint their own NFT collection without
// writing Gno code, this single realm hosts many independent GRC-721
// token instances ("collections") in an internal registry: users call
// CreateCollection to register one, then Mint into it.
package nft

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/tokens/grc721"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// MaxRoyaltyPercent caps creator royalties at 50% of a secondary sale.
const MaxRoyaltyPercent = 50

// nftToken is the subset of *grc721.royaltyNFT's method set this realm
// depends on. grc721.NewNFTWithRoyalty returns a pointer to an unexported
// concrete type, so it can't be named as a struct field type directly;
// Go/Gno interface satisfaction is structural, so this local interface
// lets us store it in Collection.token and keep the file readable.
type nftToken interface {
	Name() string
	Symbol() string
	TokenCount() int64
	BalanceOf(addr address) (int64, error)
	OwnerOf(tid grc721.TokenID) (address, error)
	TokenURI(tid grc721.TokenID) (string, error)
	SetTokenURI(caller address, tid grc721.TokenID, tURI grc721.TokenURI) (bool, error)
	IsApprovedForAll(owner, operator address) bool
	Approve(caller, to address, tid grc721.TokenID) error
	GetApproved(tid grc721.TokenID) (address, error)
	SetApprovalForAll(caller, operator address, approved bool) error
	TransferFrom(caller, from, to address, tid grc721.TokenID) error
	Mint(to address, tid grc721.TokenID) error
	Burn(tid grc721.TokenID) error
	RoyaltyInfo(tid grc721.TokenID, salePrice int64) (address, int64, error)
	SetTokenRoyalty(caller address, tid grc721.TokenID, info grc721.RoyaltyInfo) error
}

// Collection is one user-created NFT collection living inside this realm.
type Collection struct {
	id          string
	name        string
	symbol      string
	description string
	baseURI     string
	creator     address
	maxSupply   int64
	publicMint  bool // if true, anyone can Mint; otherwise only the creator
	royaltyPct  int64
	token       nftToken
	nextTokenID int64
	createdAt   int64
}

// CollectionInfo is the read-only, exported view of a Collection returned
// by view functions (safe to marshal / qeval from outside the realm).
type CollectionInfo struct {
	ID          string
	Name        string
	Symbol      string
	Description string
	BaseURI     string
	Creator     address
	MaxSupply   int64
	Minted      int64
	PublicMint  bool
	RoyaltyPct  int64
	CreatedAt   int64
}

var (
	collections          = avl.NewTree() // id -> *Collection
	collectionsByCreator = avl.NewTree() // "creator:id" -> id
	ownerIndex           = avl.NewTree() // "owner:collectionId:tokenId" -> true
	collCount            int64
)

// CreateCollection registers a brand-new GRC-721 collection owned by the
// caller and returns its collection ID. Set publicMint to true to let
// anyone mint into the collection; otherwise only the creator can.
func CreateCollection(cur realm, name, symbol, description, baseURI string, maxSupply, royaltyPct int64, publicMint bool) string {
	// Origin-caller (the tx's real signer) is used instead of
	// cur.Previous().Address() here: CreateCollection/Mint/Approve are
	// always meant to be invoked directly by a user, and per the gno.land
	// interrealm-phase-3 guidance, "PreviousRealm-based auth ... was not
	// a reliable immediate-caller check and should not be used as an
	// authorization boundary" for this kind of direct-EOA-action. Only
	// TransferFrom below actually needs the direct-caller distinction
	// (to let the marketplace act as an approved operator).
	caller := unsafe.OriginCaller()

	if maxSupply <= 0 {
		panic("maxSupply must be positive")
	}
	if royaltyPct < 0 || royaltyPct > MaxRoyaltyPercent {
		panic("royaltyPct must be between 0 and " + strconv.Itoa(MaxRoyaltyPercent))
	}

	collCount++
	id := strconv.FormatInt(collCount, 10)

	token := grc721.NewNFTWithRoyalty(0, cur, name, symbol)

	c := &Collection{
		id:          id,
		name:        name,
		symbol:      symbol,
		description: description,
		baseURI:     baseURI,
		creator:     caller,
		maxSupply:   maxSupply,
		publicMint:  publicMint,
		royaltyPct:  royaltyPct,
		token:       token,
		nextTokenID: 1,
		createdAt:   runtime.ChainHeight(),
	}
	collections.Set(id, c)
	collectionsByCreator.Set(caller.String()+":"+id, id)

	chain.Emit(
		"CollectionCreated",
		"id", id,
		"creator", caller.String(),
		"name", name,
		"symbol", symbol,
	)

	return id
}

// Mint mints the next token in a collection to the caller and returns the
// new token ID. Blocked once the collection reaches its declared max
// supply, and restricted to the collection creator unless publicMint was
// enabled at creation time.
func Mint(cur realm, collectionID, tokenURI string) string {
	caller := unsafe.OriginCaller()
	c := mustGetCollection(collectionID)

	if !c.publicMint && caller != c.creator {
		panic("minting into this collection is restricted to its creator")
	}
	if c.token.TokenCount() >= c.maxSupply {
		panic("collection has reached its max supply")
	}

	tidStr := strconv.FormatInt(c.nextTokenID, 10)
	c.nextTokenID++
	tid := grc721.TokenID(tidStr)

	if err := c.token.Mint(caller, tid); err != nil {
		panic(err)
	}
	if tokenURI != "" {
		if _, err := c.token.SetTokenURI(caller, tid, grc721.TokenURI(tokenURI)); err != nil {
			panic(err)
		}
	}
	if c.royaltyPct > 0 {
		// Newly minted tokens are owned by caller, so caller satisfies
		// SetTokenRoyalty's "caller must be current owner" check.
		if err := c.token.SetTokenRoyalty(caller, tid, grc721.RoyaltyInfo{
			PaymentAddress: c.creator,
			Percentage:     c.royaltyPct,
		}); err != nil {
			panic(err)
		}
	}

	ownerIndex.Set(caller.String()+":"+collectionID+":"+tidStr, true)

	chain.Emit(
		"NFTMinted",
		"collection", collectionID,
		"tokenId", tidStr,
		"to", caller.String(),
	)

	return tidStr
}

// Transfer / approval wrappers.
//
// Approve/SetApprovalForAll/Burn are direct EOA actions, so they use
// unsafe.OriginCaller() like Mint/CreateCollection above. TransferFrom is
// the exception: it derives caller from cur.Previous().Address() — the
// direct/immediate caller of this specific frame — because
// gno.land/r/hazen/nftmarket calls it via cross(cur) once a seller has
// approved the marketplace's realm address. From the token's perspective,
// the "caller" of that transfer must be the marketplace realm itself
// (the approved operator), not OriginCaller() (which would still be the
// buyer and was never approved to move the seller's token).

// Approve approves `to` to transfer a single token on the caller's behalf.
func Approve(cur realm, collectionID, tokenID string, to address) {
	caller := unsafe.OriginCaller()
	c := mustGetCollection(collectionID)
	if err := c.token.Approve(caller, to, grc721.TokenID(tokenID)); err != nil {
		panic(err)
	}
}

// SetApprovalForAll grants/revokes operator permission across all of the
// caller's tokens in one collection (e.g. approving the marketplace realm
// once instead of per-token).
func SetApprovalForAll(cur realm, collectionID string, operator address, approved bool) {
	caller := unsafe.OriginCaller()
	c := mustGetCollection(collectionID)
	if err := c.token.SetApprovalForAll(caller, operator, approved); err != nil {
		panic(err)
	}
}

// TransferFrom transfers a token from `from` to `to`. caller must be the
// owner or an approved operator/spender.
func TransferFrom(cur realm, collectionID, tokenID string, from, to address) {
	caller := cur.Previous().Address()
	c := mustGetCollection(collectionID)
	tid := grc721.TokenID(tokenID)

	if err := c.token.TransferFrom(caller, from, to, tid); err != nil {
		panic(err)
	}

	ownerIndex.Remove(from.String() + ":" + collectionID + ":" + tokenID)
	ownerIndex.Set(to.String()+":"+collectionID+":"+tokenID, true)

	chain.Emit(
		"Transfer",
		"collection", collectionID,
		"tokenId", tokenID,
		"from", from.String(),
		"to", to.String(),
	)
}

// Burn destroys a token. caller must be the token's current owner.
func Burn(cur realm, collectionID, tokenID string) {
	caller := unsafe.OriginCaller()
	c := mustGetCollection(collectionID)
	tid := grc721.TokenID(tokenID)

	owner, err := c.token.OwnerOf(tid)
	if err != nil {
		panic(err)
	}
	if owner != caller {
		panic("only the token owner can burn it")
	}
	if err := c.token.Burn(tid); err != nil {
		panic(err)
	}

	ownerIndex.Remove(owner.String() + ":" + collectionID + ":" + tokenID)

	chain.Emit("Burn", "collection", collectionID, "tokenId", tokenID, "from", owner.String())
}

// Read-only views.

// GetCollection returns the exported view of one collection.
func GetCollection(collectionID string) CollectionInfo {
	c := mustGetCollection(collectionID)
	return toInfo(c)
}

// ListCollections returns up to `limit` collections starting at `offset`,
// most-recently-created first is NOT guaranteed; ordering follows
// collection ID (creation order).
func ListCollections(offset, limit int64) []CollectionInfo {
	out := make([]CollectionInfo, 0, limit)
	collections.IterateByOffset(int(offset), int(limit), func(key string, value any) bool {
		out = append(out, toInfo(value.(*Collection)))
		return false
	})
	return out
}

// CollectionCount returns the total number of collections ever created.
func CollectionCount() int64 {
	return collCount
}

// TokensOfOwner returns "collectionId:tokenId" pairs for every token the
// given address owns, across every collection in this realm.
func TokensOfOwner(owner address) []string {
	var out []string
	prefix := owner.String() + ":"
	end := owner.String() + ";" // ';' immediately follows ':' in ASCII
	ownerIndex.Iterate(prefix, end, func(key string, value any) bool {
		out = append(out, key[len(prefix):])
		return false
	})
	return out
}

// BalanceOf returns how many tokens of one collection an address owns.
func BalanceOf(collectionID string, owner address) int64 {
	c := mustGetCollection(collectionID)
	bal, err := c.token.BalanceOf(owner)
	if err != nil {
		panic(err)
	}
	return bal
}

// OwnerOf returns the current owner of a token.
func OwnerOf(collectionID, tokenID string) (address, error) {
	c := mustGetCollection(collectionID)
	return c.token.OwnerOf(grc721.TokenID(tokenID))
}

// TokenURI returns the metadata URI of a token.
func TokenURI(collectionID, tokenID string) (string, error) {
	c := mustGetCollection(collectionID)
	return c.token.TokenURI(grc721.TokenID(tokenID))
}

// GetApproved returns the address approved for a single token, if any.
func GetApproved(collectionID, tokenID string) (address, error) {
	c := mustGetCollection(collectionID)
	return c.token.GetApproved(grc721.TokenID(tokenID))
}

// IsApprovedForAll reports whether operator can manage all of owner's
// tokens in one collection.
func IsApprovedForAll(collectionID string, owner, operator address) bool {
	c := mustGetCollection(collectionID)
	return c.token.IsApprovedForAll(owner, operator)
}

// RoyaltyInfo returns the payment address and royalty amount owed for a
// sale of the given token at salePrice (in the marketplace's denom units).
func RoyaltyInfo(collectionID, tokenID string, salePrice int64) (address, int64, error) {
	c := mustGetCollection(collectionID)
	return c.token.RoyaltyInfo(grc721.TokenID(tokenID), salePrice)
}

// Render implements the gno.land realm home-page convention so the
// factory is browsable directly from a gnoweb / explorer UI even without
// the dedicated frontend.
func Render(path string) string {
	if path != "" {
		id := path
		c := collections.Get(id)
		if c == nil {
			return "# 404\n\ncollection not found: " + id
		}
		return renderCollection(c.(*Collection))
	}

	out := ufmt.Sprintf("# Hazen NFT Factory\n\n%d collection(s)\n\n", collCount)
	collections.Iterate("", "", func(key string, value any) bool {
		c := value.(*Collection)
		out += ufmt.Sprintf(
			"- [#%s %s (%s)](/r/hazen/nft:%s) — %d/%d minted, by %s\n",
			c.id, c.name, c.symbol, c.id, c.token.TokenCount(), c.maxSupply, c.creator.String(),
		)
		return false
	})
	return out
}

func renderCollection(c *Collection) string {
	out := ufmt.Sprintf("# %s (%s)\n\n%s\n\n", c.name, c.symbol, c.description)
	out += ufmt.Sprintf("- Creator: %s\n", c.creator.String())
	out += ufmt.Sprintf("- Minted: %d / %d\n", c.token.TokenCount(), c.maxSupply)
	out += ufmt.Sprintf("- Public mint: %t\n", c.publicMint)
	out += ufmt.Sprintf("- Royalty: %d%%\n", c.royaltyPct)
	return out
}

func toInfo(c *Collection) CollectionInfo {
	return CollectionInfo{
		ID:          c.id,
		Name:        c.name,
		Symbol:      c.symbol,
		Description: c.description,
		BaseURI:     c.baseURI,
		Creator:     c.creator,
		MaxSupply:   c.maxSupply,
		Minted:      c.token.TokenCount(),
		PublicMint:  c.publicMint,
		RoyaltyPct:  c.royaltyPct,
		CreatedAt:   c.createdAt,
	}
}

func mustGetCollection(id string) *Collection {
	v := collections.Get(id)
	if v == nil {
		panic("collection not found: " + id)
	}
	return v.(*Collection)
}
