// Package memba_collections is the canonical, multi-collection NFT registry
// for the Memba open marketplace + launchpad. It is the ONE irreversible
// realm: it holds every launched collection's internal grc721 ledger, so it
// can never be redeployed without orphaning NFTs. The full frozen ABI lives
// in Memba/docs/planning/CANONICAL_COLLECTION_ABI.md (v3, build-ready).
//
// Design anchors:
//   - grc721 Reader/Writer split: the realm holds the concrete *metadataNFT
//     behind the unexported membaNFT interface; writes derive the caller from
//     unsafe.PreviousRealm().Address() inside crossing wrappers.
//   - Royalty is enforced IN-REALM as BPS (never grc721's percent/100 path).
//   - MarketTransfer is the ONLY token-movement path; only registered engines
//     may call it (the moat). There is no public TransferFrom/gift/airdrop.
//   - Both ugnot and GRC20 mint payments transit the realm via a per-denom
//     proceeds ledger; CEI ordering is frozen (effects before interactions).
package memba_collections

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/samcrew/grc721"
	"gno.land/p/nt/avl/v0"
)

// ── Tunable bounds (constants — permanent) ──────────────────────────────────
const (
	MaxRoyaltyBPS        = 1000                 // 10% hard ceiling (defensive)
	DefaultRoyaltyBPS    = 500                  // 5% applied when creator passes RoyaltySentinel
	MinCreatorRoyaltyBPS = 0                    // creators may opt fully out
	MinMintPrice         = 1000                 // 0.001 GNOT — anti-truncation
	MaxPriceUgnot        = 1_000_000_000_000_000 // 1e15
	MaxPrimaryFeeBPS     = 2000                 // 20% — bounds primaryFeeBPS so MaxPriceUgnot*bps < MaxInt64
	RoyaltySentinel      = -1                   // CreateCollection royaltyBPS sentinel → DefaultRoyaltyBPS
	MaxSlugLen           = 64
)

// AdminAddress is the Samouraï 2-of-2 multisig (samcrew-core-test1). Seeds
// platformAdmin, pauser, and feeRecipient at genesis; all three are mutable.
const AdminAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

// ── Platform state (mutable; platformAdmin → memba_dao executor on mainnet) ─
var (
	platformAdmin        address
	pendingPlatformAdmin address
	pauser               address // SEPARATE fast-pause role (multisig)
	feeRecipient         address // createFee + primaryFee sink (DAO treasury)
	createFee            int64   // anti-spam launch fee
	primaryFeeBPS        int64   // platform cut on primary mints (default 0; <= MaxPrimaryFeeBPS)
	maxCreatorRoyaltyBPS int64   // creator-set royalty cap (default 750)
	allowedDenoms        = avl.NewTree() // denom key -> bool (curated mint tokens; seed "ugnot")
	registeredMarkets    = avl.NewTree() // marketAddr string -> bool (DRAIN KEY)
	paused               bool            // global pause
	collections          = avl.NewTree() // collectionID "creator/slug" -> *collection
)

func init() {
	platformAdmin = address(AdminAddress)
	pauser = address(AdminAddress)
	feeRecipient = address(AdminAddress)
	createFee = 1_000_000 // 1 GNOT
	primaryFeeBPS = 0
	maxCreatorRoyaltyBPS = 750
	allowedDenoms.Set("ugnot", true)
}

// membaNFT is the subset of *grc721.metadataNFT the realm calls (verified
// against grc721_metadata.gno). NO royalty methods — royalty is in-realm.
// Burn takes no caller (wrapper own-checks); SetTokenURI returns (bool, error).
type membaNFT interface {
	Name() string
	Symbol() string
	TokenCount() int64
	BalanceOf(owner address) (int64, error)
	OwnerOf(tid grc721.TokenID) (address, error)
	GetApproved(tid grc721.TokenID) (address, error)
	IsApprovedForAll(owner, operator address) bool
	TokenURI(tid grc721.TokenID) (string, error)
	Mint(to address, tid grc721.TokenID) error
	Approve(caller, to address, tid grc721.TokenID) error
	SetApprovalForAll(caller, operator address, approved bool) error
	TransferFrom(caller, from, to address, tid grc721.TokenID) error
	SetTokenURI(caller address, tid grc721.TokenID, tURI grc721.TokenURI) (bool, error)
	Burn(tid grc721.TokenID) error
}

type royalty struct {
	recip address
	bps   int64
}

type collection struct {
	nft          membaNFT // *grc721.metadataNFT (internal ledger)
	creator      address  // immutable record of who launched it
	admin        address  // mutable (2-step; platformAdmin break-glass)
	pendingAdmin address
	// royalty — ALL in-realm, BPS
	royaltyRecip address
	royaltyBPS   int64
	tokenRoyalty *avl.Tree // tokenId -> royalty (per-token override; PRESENCE wins)
	// mint config
	phase              int    // 0 draft, 1 allowlist, 2 public, 3 closed
	allowlistRoot      string // hex sha256 root (tagged-hash; leaf=sha256(0x00‖addr.String()‖":"‖maxQty))
	mintPrice          int64  // [MinMintPrice, MaxPriceUgnot]
	payDenom           string // "" / "ugnot" = native; else an allowedDenoms key
	maxSupply          int64  // 0 = unlimited; gate on nextAutoTokenID (NOT TokenCount)
	maxPerWallet       int64  // 0 = unlimited (UX guard)
	mintStartBlock     int64  // 0 = open; else mint allowed only at/after this height
	mintCooldownBlocks int64  // 0 = none; per-wallet cooldown
	mintedByWallet     *avl.Tree // minter -> count
	lastMintBlock      *avl.Tree // minter -> last mint height
	nextAutoTokenID    int64     // sequential id for ALL mints; ALSO the supply counter
	mintCustody        address   // fixed-at-create creator sink for withdrawn proceeds
	proceeds           *avl.Tree // denom -> accrued creatorAmt
	meta               *avl.Tree // extensible per-collection flags (platformAdmin)
	paused             bool      // per-collection pause
	mintGuard          bool      // reentrancy guard for mint + withdraw + refund
}

// ── Helpers ─────────────────────────────────────────────────────────────────

func mustGet(id string) *collection {
	v, ok := collections.Get(id)
	if !ok {
		panic("collection not found: " + id)
	}
	return v.(*collection)
}

func caller() address { return unsafe.PreviousRealm().Address() }

func assertPlatformAdmin() {
	if caller() != platformAdmin {
		panic("platform admin only")
	}
}

func assertCollectionAdmin(c *collection) {
	if caller() != c.admin {
		panic("collection admin only")
	}
}

func assertNotPaused(c *collection) {
	if paused || c.paused {
		panic("paused")
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

// validSlug enforces the frozen charset ^[a-z0-9-]{1,64}$ (B-2). Rejecting
// '/' and ':' prevents collectionID ("creator/slug") namespace spoofing.
func validSlug(s string) bool {
	if len(s) == 0 || len(s) > MaxSlugLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
			return false
		}
	}
	return true
}

// ── Launchpad: CreateCollection + 2-step collection admin transfer ──────────

// CreateCollection launches a new collection. Open + fee-gated: anyone may
// call it, paying createFee in ugnot. royaltyBPS == RoyaltySentinel(-1) uses
// DefaultRoyaltyBPS; otherwise it is clamped to [MinCreatorRoyaltyBPS,
// maxCreatorRoyaltyBPS]. name/symbol are COSMETIC only — identity is the
// derived collectionID = caller/slug.
func CreateCollection(cur realm, slug, name, symbol string, royaltyBPS int64, royaltyRecip, mintCustody address, maxSupply, maxPerWallet int64) string {
	if !unsafe.PreviousRealm().IsUserCall() {
		panic("must be a direct user call")
	}
	return createCollectionInternal(cur, caller(), unsafe.OriginSend(), slug, name, symbol, royaltyBPS, royaltyRecip, mintCustody, maxSupply, maxPerWallet)
}

// createCollectionInternal holds the full create logic with the caller and
// sent coins passed explicitly, so it is unit-testable without the IsUserCall
// guard (which is unreachable for a direct test-body cross-call).
func createCollectionInternal(cur realm, cr address, sentCoins chain.Coins, slug, name, symbol string, royaltyBPS int64, royaltyRecip, mintCustody address, maxSupply, maxPerWallet int64) string {
	if paused {
		panic("paused")
	}
	if !validSlug(slug) {
		panic("invalid slug: must match ^[a-z0-9-]{1,64}$")
	}
	id := cr.String() + "/" + slug
	if _, ok := collections.Get(id); ok {
		panic("collection exists: " + id)
	}
	// createFee gate (native ugnot). Any ugnot beyond createFee is refunded to
	// the creator — including the entire envelope when createFee==0, so a free
	// create never traps attached funds (LOW stuck-funds trap).
	sent := sumDenom(sentCoins, "ugnot")
	if createFee > 0 {
		if sent < createFee {
			panic("insufficient createFee")
		}
		sendNative(cur, feeRecipient, createFee)
	}
	if over := sent - createFee; over > 0 {
		sendNative(cur, cr, over)
	}
	// royalty resolution
	rbps := royaltyBPS
	if rbps == RoyaltySentinel {
		rbps = DefaultRoyaltyBPS
	}
	if rbps < MinCreatorRoyaltyBPS {
		rbps = MinCreatorRoyaltyBPS
	}
	if rbps > maxCreatorRoyaltyBPS {
		rbps = maxCreatorRoyaltyBPS
	}
	if mintCustody == "" {
		mintCustody = cr
	}
	if royaltyRecip == "" {
		royaltyRecip = cr
	}
	c := &collection{
		nft:             grc721.NewNFTWithMetadata(0, cur, name, symbol),
		creator:         cr,
		admin:           cr,
		royaltyRecip:    royaltyRecip,
		royaltyBPS:      rbps,
		tokenRoyalty:    avl.NewTree(),
		maxSupply:       maxSupply,
		maxPerWallet:    maxPerWallet,
		mintedByWallet:  avl.NewTree(),
		lastMintBlock:   avl.NewTree(),
		mintCustody:     mintCustody,
		proceeds:        avl.NewTree(),
		meta:            avl.NewTree(),
	}
	collections.Set(id, c)
	chain.Emit("CollectionCreated",
		"collectionID", id,
		"creator", cr.String(),
		"name", name,
		"symbol", symbol,
		"royaltyBPS", itoa(rbps),
		"royaltyRecip", royaltyRecip.String(),
		"maxSupply", itoa(maxSupply),
		"createFee", itoa(createFee),
		"block", itoa(chainHeight()),
	)
	return id
}

// SetCollectionAdmin proposes a new collection admin (step 1 of 2).
func SetCollectionAdmin(cur realm, id string, newAdmin address) {
	c := mustGet(id)
	assertCollectionAdmin(c)
	c.pendingAdmin = newAdmin
	chain.Emit("CollectionAdminTransferred", "collectionID", id, "pending", newAdmin.String())
}

// AcceptCollectionAdmin completes the transfer (step 2 of 2).
func AcceptCollectionAdmin(cur realm, id string) {
	c := mustGet(id)
	if caller() != c.pendingAdmin {
		panic("not pending admin")
	}
	c.admin = c.pendingAdmin
	c.pendingAdmin = ""
	chain.Emit("CollectionAdminAccepted", "collectionID", id, "admin", c.admin.String())
}
