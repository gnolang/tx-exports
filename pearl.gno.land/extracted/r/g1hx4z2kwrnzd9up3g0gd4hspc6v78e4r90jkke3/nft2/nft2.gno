// Package nft2 is the v2 GRC-721 NFT factory realm for gnoNFT.
//
// WHY A V2 AT ALL
//
// gno.land packages are immutable once deployed, so none of the fixes
// below could be retrofitted onto gno.land/r/g1hx4z2.../nft. v2 was
// deployed while v1 still held 0 minted tokens, i.e. at the only moment
// in the project's life where migrating costs nothing.
//
// WHAT CHANGED VS V1
//
//  1. Authorization no longer uses unsafe.OriginCaller().
//     v1 justified OriginCaller with a comment claiming PreviousRealm-based
//     auth "was not a reliable immediate-caller check". That misread the
//     upstream warning: the unreliable symbol is unsafe.PreviousRealm(),
//     which stack-walks. A threaded `cur realm` parameter's cur.Previous()
//     is, in gno.land's own words, "statically scoped to a crossing
//     function and cannot lie". OriginCaller is gno's tx.origin and the
//     stdlib documents it as the Solidity tx.origin phishing class: any
//     realm the user calls could invoke
//     nft.SetApprovalForAll(cross(cur), id, attacker, true) and have v1
//     attribute it to the *user*, handing an attacker every NFT that user
//     owns. Every state-changing function here derives its caller from
//     cur.Previous().Address() instead, so a malicious intermediate realm
//     can only ever act as itself.
//
//  2. Max supply is enforced against the ID counter, not the live count.
//     v1 checked `token.TokenCount() >= maxSupply`, and TokenCount() is a
//     live count that Burn decrements — so burning re-opened mint slots
//     and a 10-supply collection could mint unbounded tokens over time.
//     v2 gates on nextTokenID and tracks mintedTotal separately, so
//     "10 max supply" means 10 tokens ever, forever.
//
//  3. Per-wallet mint caps are trustless. v1's cap lived in a separate
//     nftlimits realm that nft.Mint never consulted, so it was bypassable
//     by calling Mint directly with gnokey. Here the cap is checked inside
//     Mint itself.
//
//  4. Preset artwork queues are built in, for the same reason.
//
//  5. On-chain attributes. Traits can be stored on-chain at mint time and
//     TokenMetadata() assembles a full metadata JSON document inside the
//     realm, so a token can be fully self-describing with no IPFS, no
//     gateway and no pinning service in the trust path.
//
//  6. New views the frontend previously had to brute-force:
//     TokensOfCollection (v1 had no way to list a collection's tokens
//     except probing IDs one by one) and MintedByWallet.
package nft2

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/tokens/grc721"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	// MaxRoyaltyPercent caps creator royalties at 50% of a secondary sale.
	MaxRoyaltyPercent = 50
	// MaxAttributesPerToken and MaxTraitLen bound on-chain trait storage so
	// the attributes tree can't be used as unmetered blob storage.
	MaxAttributesPerToken = 16
	MaxTraitLen           = 64
	// MaxNameLen / MaxDescriptionLen / MaxURILen bound collection metadata.
	MaxNameLen        = 64
	MaxSymbolLen      = 16
	MaxDescriptionLen = 512
	MaxURILen         = 700_000 // fully on-chain data: URIs are the point; MaxTxBytes is the real ceiling
)

// nftToken is the subset of *grc721.royaltyNFT this realm depends on.
// grc721.NewNFTWithRoyalty returns a pointer to an unexported concrete
// type, so it can't be named as a struct field type directly; Gno
// interface satisfaction is structural, so this local interface lets us
// store it in Collection.token.
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

// Attribute is one on-chain trait of a token (OpenSea-style trait_type/value).
type Attribute struct {
	TraitType string
	Value     string
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

	// nextTokenID only ever increases. It is the supply gate (see the
	// package doc, change #2): burning a token does NOT free its slot.
	nextTokenID int64
	// mintedTotal counts tokens ever minted; token.TokenCount() counts
	// tokens currently alive. They differ once anything is burned, and the
	// UI wants to show both.
	mintedTotal int64

	// maxPerWallet is a trustless per-wallet cap (0 = unlimited), checked
	// inside Mint. mintedBy tracks lifetime mints per wallet, so the cap
	// can't be reset by burning or transferring away.
	maxPerWallet int64
	mintedBy     *avl.Tree // address.String() -> int64

	// presetURIs is an optional creator-supplied reveal queue; when it is
	// non-empty, MintNext draws the next un-revealed URI instead of
	// trusting whatever URI the minter passes.
	presetURIs []string
	presetNext int

	createdAt int64
}

// CollectionInfo is the read-only, exported view of a Collection.
// Minted is the live (un-burned) count, kept under v1's field name so the
// frontend's existing decoder keeps working; MintedTotal is new.
type CollectionInfo struct {
	ID               string
	Name             string
	Symbol           string
	Description      string
	BaseURI          string
	Creator          address
	MaxSupply        int64
	Minted           int64
	MintedTotal      int64
	PublicMint       bool
	RoyaltyPct       int64
	MaxPerWallet     int64
	PresetsTotal     int64
	PresetsRemaining int64
	CreatedAt        int64
}

var (
	collections          = avl.NewTree() // id -> *Collection
	collectionsByCreator = avl.NewTree() // "creator:id" -> id
	ownerIndex           = avl.NewTree() // "owner:collectionId:tokenId" -> true
	collectionTokens     = avl.NewTree() // "collectionId:paddedTokenId" -> tokenId
	attributes           = avl.NewTree() // "collectionId:tokenId" -> []Attribute
	collCount            int64
)

// callerOf returns the identity this realm authorizes against: the
// immediate caller frame. For a direct wallet call that is the signer;
// for a cross-realm call it is the calling realm's own address, never the
// original signer. See the package doc, change #1.
func callerOf(cur realm) address {
	return cur.Previous().Address()
}

// CreateCollection registers a brand-new GRC-721 collection owned by the
// caller and returns its collection ID. Set publicMint to true to let
// anyone mint into the collection; otherwise only the creator can. Pass
// maxPerWallet = 0 for no per-wallet cap.
func CreateCollection(cur realm, name, symbol, description, baseURI string, maxSupply, royaltyPct, maxPerWallet int64, publicMint bool) string {
	caller := callerOf(cur)

	if name == "" {
		panic("name must not be empty")
	}
	if len(name) > MaxNameLen {
		panic("name too long (max " + strconv.Itoa(MaxNameLen) + " chars)")
	}
	if len(symbol) > MaxSymbolLen {
		panic("symbol too long (max " + strconv.Itoa(MaxSymbolLen) + " chars)")
	}
	if len(description) > MaxDescriptionLen {
		panic("description too long (max " + strconv.Itoa(MaxDescriptionLen) + " chars)")
	}
	if len(baseURI) > MaxURILen {
		panic("baseURI too long")
	}
	if maxSupply <= 0 {
		panic("maxSupply must be positive")
	}
	if royaltyPct < 0 || royaltyPct > MaxRoyaltyPercent {
		panic("royaltyPct must be between 0 and " + strconv.Itoa(MaxRoyaltyPercent))
	}
	if maxPerWallet < 0 {
		panic("maxPerWallet must be >= 0 (0 means unlimited)")
	}

	collCount++
	id := strconv.FormatInt(collCount, 10)

	c := &Collection{
		id:           id,
		name:         name,
		symbol:       symbol,
		description:  description,
		baseURI:      baseURI,
		creator:      caller,
		maxSupply:    maxSupply,
		publicMint:   publicMint,
		royaltyPct:   royaltyPct,
		token:        grc721.NewNFTWithRoyalty(0, cur, name, symbol),
		nextTokenID:  1,
		maxPerWallet: maxPerWallet,
		mintedBy:     avl.NewTree(),
		createdAt:    runtime.ChainHeight(),
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
// new token ID.
func Mint(cur realm, collectionID, tokenURI string) string {
	return mint(cur, callerOf(cur), collectionID, tokenURI, "")
}

// MintWithTraits mints like Mint and additionally records on-chain traits.
// traits is a compact "trait=value;trait=value" string because gno.land's
// vm.MsgCall only carries scalar string arguments — the same reason batch
// minting loops single calls instead of passing an array.
func MintWithTraits(cur realm, collectionID, tokenURI, traits string) string {
	return mint(cur, callerOf(cur), collectionID, tokenURI, traits)
}

// MintNext draws the next un-revealed URI from the collection's preset
// queue and mints it to the caller, so the minter has no say over which
// artwork they receive.
func MintNext(cur realm, collectionID string) string {
	caller := callerOf(cur)
	c := mustGetCollection(collectionID)
	if len(c.presetURIs) == 0 {
		panic("this collection has no preset artwork queue - mint normally instead")
	}
	if c.presetNext >= len(c.presetURIs) {
		panic("no preset artwork left to reveal - the queue is exhausted")
	}
	uri := c.presetURIs[c.presetNext]
	c.presetNext++
	return mint(cur, caller, collectionID, uri, "")
}

func mint(cur realm, caller address, collectionID, tokenURI, traits string) string {
	c := mustGetCollection(collectionID)

	if !c.publicMint && caller != c.creator {
		panic("minting into this collection is restricted to its creator")
	}
	// Supply gate on the ID counter, not the live count: burning must not
	// re-open a slot (see package doc, change #2).
	if c.nextTokenID > c.maxSupply {
		panic("collection has reached its max supply")
	}
	if len(tokenURI) > MaxURILen {
		panic("tokenURI too long")
	}

	// Trustless per-wallet cap, counted over lifetime mints so it survives
	// burning and transferring away (see package doc, change #3).
	if c.maxPerWallet > 0 {
		if mintedByWallet(c, caller) >= c.maxPerWallet {
			panic("wallet has reached this collection's per-wallet mint limit of " +
				strconv.FormatInt(c.maxPerWallet, 10))
		}
	}

	attrs := parseTraits(traits)

	tidStr := strconv.FormatInt(c.nextTokenID, 10)
	c.nextTokenID++
	c.mintedTotal++
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
		// Freshly minted tokens are owned by caller, so caller satisfies
		// SetTokenRoyalty's "caller must be current owner" check.
		if err := c.token.SetTokenRoyalty(caller, tid, grc721.RoyaltyInfo{
			PaymentAddress: c.creator,
			Percentage:     c.royaltyPct,
		}); err != nil {
			panic(err)
		}
	}

	c.mintedBy.Set(caller.String(), mintedByWallet(c, caller)+1)
	ownerIndex.Set(caller.String()+":"+collectionID+":"+tidStr, true)
	collectionTokens.Set(collectionID+":"+padID(tidStr), tidStr)
	if len(attrs) > 0 {
		attributes.Set(collectionID+":"+tidStr, attrs)
	}

	chain.Emit(
		"NFTMinted",
		"collection", collectionID,
		"tokenId", tidStr,
		"to", caller.String(),
	)

	return tidStr
}

// QueuePresetURI appends one tokenURI to a collection's reveal queue.
// Creator-only.
func QueuePresetURI(cur realm, collectionID, uri string) {
	caller := callerOf(cur)
	c := mustGetCollection(collectionID)
	if caller != c.creator {
		panic("only the collection's creator can queue preset artwork")
	}
	if uri == "" {
		panic("uri must not be empty")
	}
	if len(uri) > MaxURILen {
		panic("uri too long")
	}
	if int64(len(c.presetURIs)) >= c.maxSupply {
		panic("preset queue is already as large as the collection's max supply")
	}
	c.presetURIs = append(c.presetURIs, uri)
}

// SetMaxPerWallet sets (0 clears) the trustless per-wallet mint cap.
// Creator-only. Lowering it never retroactively invalidates existing
// tokens; it only blocks further mints by wallets already at or over it.
func SetMaxPerWallet(cur realm, collectionID string, max int64) {
	caller := callerOf(cur)
	c := mustGetCollection(collectionID)
	if caller != c.creator {
		panic("only the collection's creator can set its mint limit")
	}
	if max < 0 {
		panic("max must be >= 0 (0 clears the limit)")
	}
	c.maxPerWallet = max
}

// Approve approves `to` to transfer a single token on the caller's behalf.
func Approve(cur realm, collectionID, tokenID string, to address) {
	caller := callerOf(cur)
	c := mustGetCollection(collectionID)
	if err := c.token.Approve(caller, to, grc721.TokenID(tokenID)); err != nil {
		panic(err)
	}
}

// SetApprovalForAll grants/revokes operator permission across all of the
// caller's tokens in one collection (e.g. approving the marketplace realm
// once instead of per-token).
func SetApprovalForAll(cur realm, collectionID string, operator address, approved bool) {
	caller := callerOf(cur)
	c := mustGetCollection(collectionID)
	if err := c.token.SetApprovalForAll(caller, operator, approved); err != nil {
		panic(err)
	}
}

// TransferFrom transfers a token from `from` to `to`. The caller must be
// the owner or an approved operator/spender — which is how nftmarket2 and
// nftoffers2 move tokens: they call this via cross(cur), so the caller
// seen here is the marketplace realm's own address, exactly the identity
// the seller approved.
func TransferFrom(cur realm, collectionID, tokenID string, from, to address) {
	caller := callerOf(cur)
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

// Burn destroys a token. Caller must be the token's current owner. The
// burned token's supply slot is never reused.
func Burn(cur realm, collectionID, tokenID string) {
	caller := callerOf(cur)
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
	collectionTokens.Remove(collectionID + ":" + padID(tokenID))
	attributes.Remove(collectionID + ":" + tokenID)

	chain.Emit("Burn", "collection", collectionID, "tokenId", tokenID, "from", owner.String())
}

// Read-only views.

// GetCollection returns the exported view of one collection.
func GetCollection(collectionID string) CollectionInfo {
	return toInfo(mustGetCollection(collectionID))
}

// ListCollections returns up to `limit` collections starting at `offset`,
// ordered by collection ID (creation order).
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
	ownerIndex.Iterate(prefix, owner.String()+";", func(key string, value any) bool {
		out = append(out, key[len(prefix):])
		return false
	})
	return out
}

// TokensOfCollection returns the live token IDs of one collection in
// ascending numeric order. v1 had no such view at all — the frontend had
// to probe OwnerOf(1..maxSupply) one RPC call at a time.
func TokensOfCollection(collectionID string, offset, limit int64) []string {
	mustGetCollection(collectionID)
	var out []string
	var seen int64
	prefix := collectionID + ":"
	collectionTokens.Iterate(prefix, collectionID+";", func(key string, value any) bool {
		if seen < offset {
			seen++
			return false
		}
		if limit > 0 && int64(len(out)) >= limit {
			return true
		}
		out = append(out, value.(string))
		seen++
		return false
	})
	return out
}

// MintedByWallet returns how many tokens of a collection an address has
// minted over its lifetime (the number the per-wallet cap is checked
// against — not the same as the current balance).
func MintedByWallet(collectionID string, wallet address) int64 {
	return mintedByWallet(mustGetCollection(collectionID), wallet)
}

// BalanceOf returns how many tokens of one collection an address owns.
func BalanceOf(collectionID string, owner address) int64 {
	bal, err := mustGetCollection(collectionID).token.BalanceOf(owner)
	if err != nil {
		panic(err)
	}
	return bal
}

// OwnerOf returns the current owner of a token.
func OwnerOf(collectionID, tokenID string) (address, error) {
	return mustGetCollection(collectionID).token.OwnerOf(grc721.TokenID(tokenID))
}

// TokenURI returns the metadata URI of a token.
func TokenURI(collectionID, tokenID string) (string, error) {
	return mustGetCollection(collectionID).token.TokenURI(grc721.TokenID(tokenID))
}

// TokenAttributes returns the on-chain traits recorded for a token.
func TokenAttributes(collectionID, tokenID string) []Attribute {
	v := attributes.Get(collectionID + ":" + tokenID)
	if v == nil {
		return nil
	}
	return v.([]Attribute)
}

// TokenMetadata assembles a complete metadata JSON document for a token
// inside the realm, so a fully on-chain token needs no IPFS, no gateway
// and no pinning service to be readable.
func TokenMetadata(collectionID, tokenID string) string {
	c := mustGetCollection(collectionID)
	uri, err := c.token.TokenURI(grc721.TokenID(tokenID))
	if err != nil {
		panic(err)
	}

	out := "{\"name\":\"" + jsonEscape(c.name+" #"+tokenID) + "\""
	out += ",\"description\":\"" + jsonEscape(c.description) + "\""
	out += ",\"image\":\"" + jsonEscape(uri) + "\""
	out += ",\"attributes\":["
	for i, a := range TokenAttributes(collectionID, tokenID) {
		if i > 0 {
			out += ","
		}
		out += "{\"trait_type\":\"" + jsonEscape(a.TraitType) +
			"\",\"value\":\"" + jsonEscape(a.Value) + "\"}"
	}
	out += "]}"
	return out
}

// GetApproved returns the address approved for a single token, if any.
func GetApproved(collectionID, tokenID string) (address, error) {
	return mustGetCollection(collectionID).token.GetApproved(grc721.TokenID(tokenID))
}

// IsApprovedForAll reports whether operator can manage all of owner's
// tokens in one collection.
func IsApprovedForAll(collectionID string, owner, operator address) bool {
	return mustGetCollection(collectionID).token.IsApprovedForAll(owner, operator)
}

// RoyaltyInfo returns the payment address and royalty amount owed for a
// sale of the given token at salePrice.
func RoyaltyInfo(collectionID, tokenID string, salePrice int64) (address, int64, error) {
	return mustGetCollection(collectionID).token.RoyaltyInfo(grc721.TokenID(tokenID), salePrice)
}

// Render implements the gno.land realm home-page convention so the
// factory is browsable from gnoweb even without the dedicated frontend.
func Render(path string) string {
	if path != "" {
		v := collections.Get(path)
		if v == nil {
			return "# 404\n\ncollection not found: " + path
		}
		return renderCollection(v.(*Collection))
	}

	out := ufmt.Sprintf("# gnoNFT Factory v2\n\n%d collection(s)\n\n", collCount)
	collections.Iterate("", "", func(key string, value any) bool {
		c := value.(*Collection)
		out += ufmt.Sprintf(
			"- [#%s %s (%s)](:%s) - %d/%d minted, by %s\n",
			c.id, c.name, c.symbol, c.id, c.mintedTotal, c.maxSupply, c.creator.String(),
		)
		return false
	})
	return out
}

func renderCollection(c *Collection) string {
	out := ufmt.Sprintf("# %s (%s)\n\n%s\n\n", c.name, c.symbol, c.description)
	out += ufmt.Sprintf("- Creator: %s\n", c.creator.String())
	out += ufmt.Sprintf("- Minted: %d / %d\n", c.mintedTotal, c.maxSupply)
	out += ufmt.Sprintf("- Currently live: %d\n", c.token.TokenCount())
	out += ufmt.Sprintf("- Public mint: %t\n", c.publicMint)
	out += ufmt.Sprintf("- Royalty: %d%%\n", c.royaltyPct)
	if c.maxPerWallet > 0 {
		out += ufmt.Sprintf("- Max per wallet: %d\n", c.maxPerWallet)
	}
	if total := len(c.presetURIs); total > 0 {
		out += ufmt.Sprintf("- Presets revealed: %d / %d\n", c.presetNext, total)
	}
	return out
}

// Internal helpers.

func mintedByWallet(c *Collection, wallet address) int64 {
	v := c.mintedBy.Get(wallet.String())
	if v == nil {
		return 0
	}
	return v.(int64)
}

// parseTraits turns "Background=Blue;Eyes=Laser" into attributes. Empty
// segments are skipped; a segment with no '=' is rejected outright rather
// than silently stored, so a typo can't be minted into a token forever.
func parseTraits(traits string) []Attribute {
	if traits == "" {
		return nil
	}
	var out []Attribute
	for _, seg := range strings.Split(traits, ";") {
		seg = strings.TrimSpace(seg)
		if seg == "" {
			continue
		}
		idx := strings.Index(seg, "=")
		if idx <= 0 || idx == len(seg)-1 {
			panic("malformed trait \"" + seg + "\": expected trait=value pairs separated by ';'")
		}
		k := strings.TrimSpace(seg[:idx])
		v := strings.TrimSpace(seg[idx+1:])
		if len(k) > MaxTraitLen || len(v) > MaxTraitLen {
			panic("trait name/value too long (max " + strconv.Itoa(MaxTraitLen) + " chars)")
		}
		out = append(out, Attribute{TraitType: k, Value: v})
		if len(out) > MaxAttributesPerToken {
			panic("too many traits (max " + strconv.Itoa(MaxAttributesPerToken) + ")")
		}
	}
	return out
}

// padID zero-pads a numeric token ID so the collectionTokens tree sorts
// numerically rather than lexicographically ("10" must come after "2").
func padID(id string) string {
	const width = 12
	if len(id) >= width {
		return id
	}
	return "000000000000"[:width-len(id)] + id
}

func jsonEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString("\\\"")
		case '\\':
			b.WriteString("\\\\")
		case '\n':
			b.WriteString("\\n")
		case '\r':
			b.WriteString("\\r")
		case '\t':
			b.WriteString("\\t")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

func toInfo(c *Collection) CollectionInfo {
	presetsTotal := int64(len(c.presetURIs))
	remaining := presetsTotal - int64(c.presetNext)
	if remaining < 0 {
		remaining = 0
	}
	return CollectionInfo{
		ID:               c.id,
		Name:             c.name,
		Symbol:           c.symbol,
		Description:      c.description,
		BaseURI:          c.baseURI,
		Creator:          c.creator,
		MaxSupply:        c.maxSupply,
		Minted:           c.token.TokenCount(),
		MintedTotal:      c.mintedTotal,
		PublicMint:       c.publicMint,
		RoyaltyPct:       c.royaltyPct,
		MaxPerWallet:     c.maxPerWallet,
		PresetsTotal:     presetsTotal,
		PresetsRemaining: remaining,
		CreatedAt:        c.createdAt,
	}
}

func mustGetCollection(id string) *Collection {
	v := collections.Get(id)
	if v == nil {
		panic("collection not found: " + id)
	}
	return v.(*Collection)
}
