package memba_nft_v2

import (
	"chain"
	"chain/runtime/unsafe"
	"math/overflow"
	"strconv"

	"gno.land/p/samcrew/grc721"
	"gno.land/p/nt/avl/v0"
)

// AdminAddress is the Samouraï 2-of-2 multisig (samcrew-core-test1).
// Root of trust: mint authority + market registration + pause.
const AdminAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

const MaxRoyaltyBPS = 1000 // 10% ceiling

// collectionID -> *collection
var collections = avl.NewTree()

// registered marketplace realm addresses allowed to call MarketTransfer.
// Adding one is a DRAIN KEY: multisig-only, event-logged.
var registeredMarkets = avl.NewTree() // addr.String() -> bool

var paused bool // global pause

// membaNFT is the local composite interface the unexported *grc721.royaltyNFT
// satisfies structurally (grc721 exposes no writer interface on test13).
type membaNFT interface {
	Name() string
	Symbol() string
	TokenCount() int64
	BalanceOf(addr address) (int64, error)
	OwnerOf(tid grc721.TokenID) (address, error)
	GetApproved(tid grc721.TokenID) (address, error)
	IsApprovedForAll(owner, operator address) bool
	TokenURI(tid grc721.TokenID) (string, error)
	Mint(to address, tid grc721.TokenID) error
	Approve(caller, to address, tid grc721.TokenID) error
	SetApprovalForAll(caller, operator address, approved bool) error
	TransferFrom(caller, from, to address, tid grc721.TokenID) error
	SetTokenURI(caller address, tid grc721.TokenID, tURI grc721.TokenURI) (bool, error)
	RoyaltyInfo(tid grc721.TokenID, salePrice int64) (address, int64, error)
	SetTokenRoyalty(caller address, tid grc721.TokenID, info grc721.RoyaltyInfo) error
}

type collection struct {
	nft           membaNFT        // basic+metadata+royalty composite (internal ledger)
	admin         address         // per-collection admin (v1: AdminAddress)
	royaltyRecip  address         // MUTABLE
	royaltyBPS    int64           // <= MaxRoyaltyBPS
	phase         int             // 0=curated/multisig-only,1=allowlist,2=public (v1: 0)
	allowlistRoot string
	mintPrice     int64
	maxSupply     int64 // 0 = unlimited
	maxPerWallet  int64
	paused        bool // per-collection pause
}

func mustGet(id string) *collection {
	v, ok := collections.Get(id)
	if !ok {
		panic("collection not found: " + id)
	}
	return v.(*collection)
}

func assertAdmin() {
	if unsafe.PreviousRealm().Address() != address(AdminAddress) {
		panic("admin only")
	}
}

func assertNotPaused(c *collection) {
	if paused || c.paused {
		panic("paused")
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// ── Group 1: CreateCollection, SetRoyalty, RoyaltyInfo ───────────────────────

func CreateCollection(cur realm, id, name, symbol string, royaltyBPS int64, royaltyRecip address, maxSupply, maxPerWallet int64) {
	assertAdmin()
	if _, ok := collections.Get(id); ok {
		panic("collection exists: " + id)
	}
	if royaltyBPS > MaxRoyaltyBPS {
		panic("royalty exceeds max")
	}
	c := &collection{
		nft:          grc721.NewNFTWithRoyalty(0, cur, name, symbol),
		admin:        address(AdminAddress),
		royaltyRecip: royaltyRecip,
		royaltyBPS:   royaltyBPS,
		maxSupply:    maxSupply,
		maxPerWallet: maxPerWallet,
	}
	collections.Set(id, c)
	chain.Emit("CollectionCreated",
		"collection", id,
		"name", name,
		"symbol", symbol,
		"royaltyBPS", itoa(royaltyBPS),
		"royaltyRecipient", royaltyRecip.String(),
	)
}

func SetRoyalty(cur realm, id string, recip address, bps int64) {
	assertAdmin()
	if bps > MaxRoyaltyBPS {
		panic("royalty exceeds max")
	}
	c := mustGet(id)
	c.royaltyRecip, c.royaltyBPS = recip, bps
	chain.Emit("RoyaltyChanged",
		"collection", id,
		"royaltyBPS", itoa(bps),
		"recipient", recip.String(),
	)
}

// RoyaltyInfo returns the collection-level royalty recipient and amount for a
// given sale price. It uses the collection's BPS rate, not per-token royalty.
func RoyaltyInfo(id string, tid grc721.TokenID, salePrice int64) (address, int64) {
	c := mustGet(id)
	return c.royaltyRecip, overflow.Mul64p(salePrice, c.royaltyBPS) / 10000
}

// ── Group 2: Mint ─────────────────────────────────────────────────────────────

func Mint(cur realm, id string, to address, tid grc721.TokenID, tokenURI string) {
	assertAdmin()
	c := mustGet(id)
	if c.maxSupply > 0 && c.nft.TokenCount() >= c.maxSupply {
		panic("max supply reached")
	}
	if err := c.nft.Mint(to, tid); err != nil {
		panic(err.Error())
	}
	if tokenURI != "" {
		// SetTokenURI checks caller == owner; after Mint, owner == to.
		if _, err := c.nft.SetTokenURI(to, tid, grc721.TokenURI(tokenURI)); err != nil {
			panic(err.Error())
		}
	}
	chain.Emit("Mint",
		"collection", id,
		"to", to.String(),
		"tokenId", string(tid),
	)
}

// ── Group 6 additions: pause fns ─────────────────────────────────────────────

func PauseCollection(cur realm, id string) {
	assertAdmin()
	mustGet(id).paused = true
	chain.Emit("CollectionPaused", "collection", id)
}

func UnpauseCollection(cur realm, id string) {
	assertAdmin()
	mustGet(id).paused = false
	chain.Emit("CollectionUnpaused", "collection", id)
}

func Pause(cur realm) {
	assertAdmin()
	paused = true
	chain.Emit("Paused")
}

func Unpause(cur realm) {
	assertAdmin()
	paused = false
	chain.Emit("Unpaused")
}

func IsPaused() bool { return paused }
