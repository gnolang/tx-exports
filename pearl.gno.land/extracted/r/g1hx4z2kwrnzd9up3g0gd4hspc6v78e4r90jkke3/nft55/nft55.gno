// Package nft55 is the v5.5 GRC-721 NFT factory realm for gnoNFT.
//
// WHAT CHANGED VS V5.4 (security + scope; no new powers, no admin)
//
//  1. Artwork URIs are validated ON CHAIN (assertSafeURI), on
//     CreateCollection(baseURI), Mint(tokenURI) and QueuePresetURI(uri).
//     Only https://, ipfs://, ar:// and data:image/ | data:application/json
//     are accepted. v5.4 persisted whatever scheme the caller supplied, so
//     a javascript: or data:text/html payload could be burned into the
//     chain permanently and then executed by any client - wallet, explorer
//     or third-party frontend - that rendered it. The realm cannot rely on
//     "the frontend will sanitize it"; an immutable record is forever.
//
//  2. No migration gate. v5.4 shipped migrate54.gno so v5.2/v5.3 holders
//     could reclaim tokens. gnoNFT launches on mainnet from a CLEAN LEDGER
//     (testnet tokens are not carried over), so v5.5 ships without the
//     gate: smaller package, cheaper deploy, and exactly the shape that
//     goes to mainnet. This does not weaken the migration policy below - a
//     future successor is still born with its gate compiled in at deploy
//     time, taking THIS realm as its source.
//
// WHAT CHANGED VS V5.3 (mint cost only — no new features, no new powers)
//
// v5.3 measured 7,782 B of storage per creator mint and 14,709 B per public
// mint on pearl-1. Every byte below was being written for data the realm
// could already derive, so v5.4 stops writing it. Nothing here relaxes a
// check, and no view changes its answer.
//
//  1. No per-token royalty row. v5.3 wrote (creator, royaltyPct) into the
//     grc721 royalty tree for EVERY token, but royaltyPct is fixed at
//     CreateCollection and creator can never be reassigned, so all N rows
//     of a collection were byte-identical copies of two collection fields.
//     RoyaltyInfo now computes the answer from the collection record. The
//     market's guarantee is unchanged: the royalty is set by the
//     collection's immutable terms, and the token holder cannot alter it.
//
//  2. No collectionTokens index. Token IDs are consecutive by construction
//     (nextTokenID only increases; a burn never re-opens a slot), so the
//     live set is 1..nextTokenID-1 minus what grc721 no longer owns.
//     TokensOfCollection derives that at read time instead of maintaining a
//     padded-key index on every mint and burn. It is a read-only view, so
//     the scan is paid by the RPC query rather than by a transaction, and
//     no write path calls it.
//
//  3. The per-wallet counter is only kept when a cap exists. With
//     maxPerWallet == 0 there is nothing to check, yet v5.3 still created
//     an AVL node per minting wallet — which is exactly why a public mint
//     by a fresh wallet cost about twice a creator mint: new tree nodes
//     instead of in-place updates.
//
// WHAT CHANGED VS V5 (all three are security or cost fixes, no new features)
//
//  A. Generative traits are DERIVED, not stored. v5 wrote the seed AND the
//     seven traits nftgen0 derives from that same seed, so every generative
//     mint paid ~12-20 KB of storage deposit (1.5-2.3 GNOT measured on
//     pearl-1) to persist data that is a pure function of a string the realm
//     already keeps. Here MintGenerative stores only the seed and
//     TokenAttributes rebuilds the traits at read time. Reads are free
//     qevals and nftgen0 is a fixed-cost pure function, so this is a strict
//     cost win with no new gas surface.
//
//  B. Trait spoofing is closed. v5.mint() stored whatever trait string the
//     CALLER supplied and only gated on publicMint, so in any public-mint
//     collection a stranger could mint themselves a token carrying
//     "Rarity=Legendary" and poison the marketplace rarity filter. In v5.2
//     only the collection creator may supply traits by hand; everyone else
//     mints traitless tokens or, in a generative collection, tokens whose
//     traits are the deterministic output of the engine. Rarity therefore
//     cannot be forged by anyone, creator included, in a generative
//     collection.
//
//  C. The rendering engine is PINNED per collection. Derived traits mean a
//     token's appearance now depends on live code rather than a stored blob,
//     so a collection records which engine realm it was created against
//     (Engine in CollectionInfo) at the moment it is marked generative.
//     gno.land realms are immutable, so a pinned engine can never change
//     under an existing token; a future nftgen1 is a different pkgpath and
//     therefore a different, explicitly recorded engine.
//
// Additionally a generative collection now refuses Mint / MintWithTraits /
// MintNext outright: mixing hand-written art or hand-written traits into a
// collection that advertises "every token is derived from its seed" would
// make that promise unverifiable.
//
// MIGRATION POLICY (why old tokens are safe when v6 arrives)
//
// Realms are immutable, so a fix always means a new pkgpath, and the
// project treats that as a first-class event rather than an accident:
// every piece of state a successor realm needs in order to reproduce a
// token exactly - seed, traits, URI, creator, royalty, per-collection
// config - is exposed here as a pure public read (GetCollection,
// TokenSeed, TokenAttributes, TokenURI, TokenMetadata, OwnerOf,
// RoyaltyInfo, TokensOfCollection). A successor can therefore import this
// realm, verify ownership on chain, and re-mint a byte-identical token to
// the rightful owner without any admin key, snapshot file or trusted
// operator existing anywhere in the path. Nothing in this realm can be
// switched off, redirected or upgraded by its deployer - there is
// deliberately no owner, no pause switch and no proxy.
//
// Inherited from v2 (kept verbatim below because the reasoning still
// applies):
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
package nft55

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/tokens/grc721"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	"gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nftgen0"
)

const (
	// MaxRoyaltyPercent caps creator royalties at 50% of a secondary sale.
	MaxRoyaltyPercent = 50
	// MaxCollectionSupply is the platform-wide ceiling on a single
	// collection. It exists so pagination, indexing and gas stay
	// predictable, and so a "collection" stays a collection instead of an
	// unbounded minting faucet. Raising it later means a new realm.
	MaxCollectionSupply = 1000
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

// Engine is the generative engine this realm renders seeds with. It is
// recorded on a collection when the collection is marked generative, so a
// token always names the exact immutable pkgpath that produced it.
const Engine = "gno.land/r/g1hx4z2kwrnzd9up3g0gd4hspc6v78e4r90jkke3/nftgen0"

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
	// v5.4 no longer writes a per-token royalty record (see package doc,
	// v5.4 change 1), so the royalty half of the grc721 surface is not part of
	// what this realm needs from its token backend any more.
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

	// onchainTokens / ipfsTokens record where each minted token's artwork
	// actually lives, so the UI can show an honest "fully on-chain" badge
	// instead of trusting the creator's word. Counted at mint time over
	// lifetime mints: burning does not decrement, same as mintedTotal.
	onchainTokens int64
	ipfsTokens    int64

	// generative marks a collection whose artwork is produced by the
	// on-chain nftgen0 engine. Such tokens store only a short seed; the
	// data: URI is rebuilt at read time by TokenURI, which is what makes a
	// generative mint cost gas instead of ~2 GNOT of storage deposit.
	generative bool

	// engine pins the pkgpath of the generator this collection's tokens are
	// rendered by. Set once, when the collection is marked generative, and
	// never rewritten - see package doc, change C.
	engine string

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
	// New in v4. Appended at the end so existing positional decoders keep
	// working for every field before them.
	OnchainTokens int64
	IpfsTokens    int64
	StorageKind   string
	// New in v5: true when tokens are rendered from an on-chain seed.
	Generative bool
	// New in v5.2: the pinned generative engine pkgpath ("" when the
	// collection is not generative).
	Engine string
}

var (
	collections          = avl.NewTree() // id -> *Collection
	collectionsByCreator = avl.NewTree() // "creator:id" -> id
	ownerIndex           = avl.NewTree() // "owner:collectionId:tokenId" -> true
	attributes           = avl.NewTree() // "collectionId:tokenId" -> []Attribute
	seeds                = avl.NewTree() // "collectionId:tokenId" -> seed string (generative tokens only)
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
	assertSafeURI(baseURI, "baseURI")
	if maxSupply <= 0 {
		panic("maxSupply must be positive")
	}
	if maxSupply > MaxCollectionSupply {
		panic("maxSupply must be at most " + strconv.Itoa(MaxCollectionSupply))
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
	assertNotGenerative(collectionID)
	return mint(cur, callerOf(cur), collectionID, tokenURI, "")
}

// MintWithTraits mints like Mint and additionally records on-chain traits.
// traits is a compact "trait=value;trait=value" string because gno.land's
// vm.MsgCall only carries scalar string arguments — the same reason batch
// minting loops single calls instead of passing an array.
// Only the collection's creator may hand-write traits: a stranger minting
// into a public collection must not be able to award themselves
// "Rarity=Legendary" and poison the marketplace filter (package doc,
// change B). Public minters can still mint - they just cannot dictate
// metadata that the market prices.
func MintWithTraits(cur realm, collectionID, tokenURI, traits string) string {
	caller := callerOf(cur)
	c := mustGetCollection(collectionID)
	if c.generative {
		panic("this collection is generative; its traits come from the engine - use MintGenerative")
	}
	if traits != "" && caller != c.creator {
		panic("only the collection's creator can set traits by hand; use Mint instead")
	}
	return mint(cur, caller, collectionID, tokenURI, traits)
}

// MintNext draws the next un-revealed URI from the collection's preset
// queue and mints it to the caller, so the minter has no say over which
// artwork they receive.
func MintNext(cur realm, collectionID string) string {
	caller := callerOf(cur)
	c := mustGetCollection(collectionID)
	if c.generative {
		panic("this collection is generative; use MintGenerative")
	}
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
	assertSafeURI(tokenURI, "tokenURI")

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
	// Where does this token's artwork live? A token with no URI of its own
	// inherits the collection's baseURI, so classify whichever one applies.
	effURI := tokenURI
	if effURI == "" {
		effURI = c.baseURI
	}
	if strings.HasPrefix(effURI, "data:") {
		c.onchainTokens++
	} else if strings.HasPrefix(effURI, "ipfs://") {
		c.ipfsTokens++
	}

	// Only pay for the per-wallet counter when a cap actually exists to
	// check it against (see package doc, v5.4 change 3). An uncapped
	// collection's first mint by a new wallet used to create a whole AVL
	// node nothing ever read.
	if c.maxPerWallet > 0 {
		c.mintedBy.Set(caller.String(), mintedByWallet(c, caller)+1)
	}
	ownerIndex.Set(caller.String()+":"+collectionID+":"+tidStr, true)
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

// SetGenerative marks (or unmarks) a collection as generative, meaning
// its tokens are minted with MintGenerative and rendered from a seed by
// the on-chain nftgen0 engine. Creator-only, and refused once anything
// has been minted so a collection can never change what its existing
// tokens look like.
func SetGenerative(cur realm, collectionID string, generative bool) {
	caller := callerOf(cur)
	c := mustGetCollection(collectionID)
	if caller != c.creator {
		panic("only the collection's creator can change its generative mode")
	}
	if c.mintedTotal > 0 {
		panic("collection already has minted tokens; generative mode is fixed")
	}
	c.generative = generative
	if generative {
		c.engine = Engine
	} else {
		c.engine = ""
	}
}

// MintGenerative mints the next token of a generative collection to the
// caller. No artwork is stored: the token keeps a seed, and its traits
// are the ones nftgen0 derives from that same seed, so the trait filter
// in the marketplace keeps working exactly as it does for stored art.
func MintGenerative(cur realm, collectionID string) string {
	caller := callerOf(cur)
	c := mustGetCollection(collectionID)
	if !c.generative {
		panic("this collection is not generative; use Mint or MintNext instead")
	}

	seed := nftgen0.SeedFor(collectionID, strconv.FormatInt(c.nextTokenID, 10))
	// The traits are NOT written to the attributes tree: they are a pure
	// function of this seed and TokenAttributes derives them on read. v5
	// stored both and paid 12-20 KB of deposit per token for the privilege
	// (package doc, change A).
	tidStr := mint(cur, caller, collectionID, "", "")

	seeds.Set(collectionID+":"+tidStr, seed)
	// The artwork is produced and served entirely by on-chain code, so it
	// is on-chain in the strongest sense - there is not even a stored blob
	// that could rot. mint() classifies by URI and a generative mint has
	// none, so it only counted this token if the collection's baseURI is
	// itself a data: URI; guard against counting it twice.
	if !strings.HasPrefix(c.baseURI, "data:") {
		c.onchainTokens++
	}

	chain.Emit(
		"GenerativeMinted",
		"collection", collectionID,
		"tokenId", tidStr,
		"seed", seed,
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
	assertSafeURI(uri, "uri")
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
	attributes.Remove(collectionID + ":" + tokenID)
	seeds.Remove(collectionID + ":" + tokenID)

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
// ascending numeric order.
//
// v5.3 answered this from a dedicated "collectionId:paddedTokenId" index
// that every mint had to write. v5.4 derives it instead: token IDs are
// consecutive 1..nextTokenID-1 by construction (nextTokenID only ever
// increases and a burn never re-opens a slot), so the live set is exactly
// that range minus whatever grc721 no longer owns. Same answer, same
// order, one less storage write per mint (see package doc, v5.4 change 2).
//
// This is a read-only view, so the scan is paid for by the RPC query, not
// by a transaction. Nothing on a write path calls it.
func TokensOfCollection(collectionID string, offset, limit int64) []string {
	c := mustGetCollection(collectionID)
	var out []string
	var seen int64
	for id := int64(1); id < c.nextTokenID; id++ {
		if limit > 0 && int64(len(out)) >= limit {
			break
		}
		tidStr := strconv.FormatInt(id, 10)
		if _, err := c.token.OwnerOf(grc721.TokenID(tidStr)); err != nil {
			continue // burned
		}
		if seen < offset {
			seen++
			continue
		}
		out = append(out, tidStr)
		seen++
	}
	return out
}

// MintedByWallet returns how many tokens of a collection an address has
// minted over its lifetime (the number the per-wallet cap is checked
// against — not the same as the current balance).
//
// v5.4 only keeps this counter for collections that actually set a cap,
// so an uncapped collection reports 0 here. That is not a lost limit:
// with maxPerWallet == 0 there is nothing to enforce, and the UI already
// treats "no cap" as unlimited rather than comparing against this number.
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
//
// For a generative token nothing is stored but a short seed: the data:
// URI is rebuilt here by the nftgen0 engine on every read. Storing a
// 4-5 KB base64 SVG per token cost roughly 2.1 GNOT of storage deposit
// in v4; a seed costs a few dozen bytes, and because the generator is
// deterministic the artwork is byte-identical forever.
func TokenURI(collectionID, tokenID string) (string, error) {
	if seed, ok := avlGet(seeds, collectionID + ":" + tokenID).(string); ok {
		return nftgen0.DataURI(seed), nil
	}
	return mustGetCollection(collectionID).token.TokenURI(grc721.TokenID(tokenID))
}

// TokenSeed returns the generative seed of a token, or "" when the token
// stores an ordinary URI.
func TokenSeed(collectionID, tokenID string) string {
	if seed, ok := avlGet(seeds, collectionID + ":" + tokenID).(string); ok {
		return seed
	}
	return ""
}

// TokenAttributes returns a token's traits.
//
// Stored traits win when they exist, so tokens minted with explicit traits
// (and any token carried over from an older realm) keep behaving exactly as
// before. A generative token has none: its traits are rebuilt here from its
// seed, which is both cheaper and unforgeable - see package doc, changes A
// and B. The output is byte-identical to what v5 used to persist, which the
// realm's test suite asserts seed by seed.
func TokenAttributes(collectionID, tokenID string) []Attribute {
	if v := avlGet(attributes, collectionID + ":" + tokenID); v != nil {
		return v.([]Attribute)
	}
	if seed, ok := avlGet(seeds, collectionID + ":" + tokenID).(string); ok {
		return deriveAttributes(seed)
	}
	return nil
}

// deriveAttributes rebuilds the trait list for a seed. It mirrors
// nftgen0.TraitString field for field; the test suite pins that equality so
// the two can never drift apart silently.
func deriveAttributes(seed string) []Attribute {
	tr := nftgen0.TraitsOf(seed)
	aura := "No"
	if tr.Aura {
		aura = "Yes"
	}
	return []Attribute{
		{TraitType: "Palette", Value: tr.Palette},
		{TraitType: "Shape", Value: tr.Shape},
		{TraitType: "Ground", Value: tr.Ground},
		{TraitType: "Elements", Value: strconv.Itoa(tr.Elements)},
		{TraitType: "Symmetry", Value: strconv.Itoa(tr.Symmetry)},
		{TraitType: "Aura", Value: aura},
		{TraitType: "Rarity", Value: tr.Rarity},
	}
}

// TokenMetadata assembles a complete metadata JSON document for a token
// inside the realm, so a fully on-chain token needs no IPFS, no gateway
// and no pinning service to be readable.
func TokenMetadata(collectionID, tokenID string) string {
	c := mustGetCollection(collectionID)
	uri, err := TokenURI(collectionID, tokenID)
	if err != nil {
		panic(err)
	}
	_ = c

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
//
// v5.4 computes this from the collection record instead of a per-token
// royalty row (package doc, v5.4 change 1). Every token in a collection
// always had the identical (creator, royaltyPct) pair written into it at
// mint time, because royaltyPct is fixed at CreateCollection and nothing
// can rewrite it afterwards — so the per-token copy was pure duplication.
// The guarantee the market cares about is unchanged: the royalty a buyer
// pays is decided by the collection's immutable terms, not by whoever
// happens to hold the token.
func RoyaltyInfo(collectionID, tokenID string, salePrice int64) (address, int64, error) {
	c := mustGetCollection(collectionID)
	// Still gate on existence, so a sale of a burned/never-minted token
	// cannot quietly report "no royalty owed" the way a missing row would.
	if _, err := c.token.OwnerOf(grc721.TokenID(tokenID)); err != nil {
		return "", 0, err
	}
	if c.royaltyPct <= 0 {
		return "", 0, nil
	}
	return c.creator, salePrice * c.royaltyPct / 100, nil
}

// Render implements the gno.land realm home-page convention so the
// factory is browsable from gnoweb even without the dedicated frontend.
func Render(path string) string {
	if path != "" {
		v := avlGet(collections, path)
		if v == nil {
			return "# 404\n\ncollection not found: " + path
		}
		return renderCollection(v.(*Collection))
	}

	out := ufmt.Sprintf("# gnoNFT Factory v5.4\n\n%d collection(s)\n\n", collCount)
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
	v := avlGet(c.mintedBy, wallet.String())
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
			if r < 0x20 {
				const hexDigits = "0123456789abcdef"
				b.WriteString("\\u00")
				b.WriteByte(hexDigits[(r>>4)&0xf])
				b.WriteByte(hexDigits[r&0xf])
				continue
			}
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
		OnchainTokens:    c.onchainTokens,
		IpfsTokens:       c.ipfsTokens,
		StorageKind:      storageKind(c),
		Generative:       c.generative,
		Engine:           c.engine,
	}
}

// storageKind reports where a collection's artwork lives:
//
//	"onchain"  every minted token is a data: URI - nothing off-chain to rot
//	"ipfs"     every minted token points at ipfs://
//	"external" plain http(s) links
//	"mixed"    a bit of both
//	"unknown"  nothing minted yet and no baseURI hint
//
// Before the first mint the baseURI is the only evidence available, so it
// is used as the hint; after that the per-token counters decide.
func storageKind(c *Collection) string {
	if c.mintedTotal == 0 {
		if strings.HasPrefix(c.baseURI, "data:") {
			return "onchain"
		}
		if strings.HasPrefix(c.baseURI, "ipfs://") {
			return "ipfs"
		}
		if c.baseURI == "" {
			return "unknown"
		}
		return "external"
	}
	if c.onchainTokens == c.mintedTotal {
		return "onchain"
	}
	if c.ipfsTokens == c.mintedTotal {
		return "ipfs"
	}
	if c.onchainTokens == 0 && c.ipfsTokens == 0 {
		return "external"
	}
	return "mixed"
}

// CollectionStorageKind exposes storageKind as a standalone view so the UI
// can badge a collection without decoding a whole CollectionInfo.
func CollectionStorageKind(collectionID string) string {
	return storageKind(mustGetCollection(collectionID))
}

// assertNotGenerative refuses hand-minting into a generative collection, so
// "every token here is derived from its seed" stays a checkable claim.
func assertNotGenerative(collectionID string) {
	if mustGetCollection(collectionID).generative {
		panic("this collection is generative; use MintGenerative")
	}
}

// assertSafeURI refuses artwork URIs that a wallet, explorer or the
// frontend could be tricked into executing. A tokenURI is rendered by
// every client that shows the collection, so a "javascript:" or
// "data:text/html" payload minted into a public collection is stored XSS
// that would live on chain forever. Only schemes that can be rendered as
// an image or parsed as metadata are accepted.
func assertSafeURI(uri, label string) {
	if uri == "" {
		return
	}
	lower := strings.ToLower(uri)
	if strings.HasPrefix(lower, "https://") ||
		strings.HasPrefix(lower, "ipfs://") ||
		strings.HasPrefix(lower, "ar://") ||
		strings.HasPrefix(lower, "data:image/") ||
		strings.HasPrefix(lower, "data:application/json") {
		return
	}
	panic(label + " must start with https://, ipfs://, ar://, data:image/ or data:application/json")
}

func mustGetCollection(id string) *Collection {
	v := avlGet(collections, id)
	if v == nil {
		panic("collection not found: " + id)
	}
	return v.(*Collection)
}
