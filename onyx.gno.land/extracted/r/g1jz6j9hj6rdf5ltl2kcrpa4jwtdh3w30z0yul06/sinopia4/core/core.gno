// Package core is the platform's immutable ledger (design §2.5.2): every
// collection, its official grc721 token and royalty, its provenance
// (commit–reveal v2), the engine registry, fees and the admin timelock.
//
// What core guarantees, whoever holds the admin key:
//
//   - I-1  admin cannot move, approve or burn a token, and holds no funds;
//     the op list is a closed set of parameters (admin.gno).
//   - I-2  pause only gates create, mint and trade. Transfer, burn,
//     finalize, distribute and every cancel stay open. A pause expires by
//     itself, cannot be renewed while it runs, and each scope has a budget
//     of MaxPauseBlocks per PauseWindowBlocks (SA-L2).
//   - I-5  supply only grows through the collection's bound minter, never
//     past maxSupply, and a token id is never minted twice.
//   - I-6  after Launch the engine, params, supply, payees, sale window,
//     commitments, randomness source and fee snapshots are frozen.
//   - I-9  MintedBy(addr) is exact while a collection is not Final:
//     grc721 balance minus the reserves sent to addr. It needs I-11 (no
//     token moves or burns before Final); if that lock is ever relaxed the
//     counter must be stored again (TestRegress_P2_*).
//   - I-10/11  a collection becomes Final at most once, only with both
//     reveals or after revealDeadline, and that deadline is bounded, so
//     the pre-reveal transfer lock always ends. With a randomness provider
//     Finalize may wait for the bound round, at most ProviderWaitBlocks
//     after the deadline or the binding (a Finalize after the deadline
//     binds), so anyone can end the lock by revealDeadline + 1 +
//     ProviderWaitBlocks + 1.
//   - I-12/I-16 engine code runs on a state-changing path only in the
//     engine user's own transaction: RegisterEngine (manifest, default
//     params, one sample render and its traits), CreateCollection
//     (ValidateParams, TraitTypes) and Launch (CheckLaunch). It never gets
//     core's cur. Every exported non-crossing function is read-only, so an
//     engine cannot call back into a mutator. An admin-approved randomness
//     provider (randomness.gno) runs only in RevealCreatorSecret,
//     RequestRandomness, FulfillRandomness and Finalize of collections
//     launched with it.
//   - I-13 every stored string passed safe.AssertText.
//   - I-14 a fingerprint reserved in source (config.gno) can only be
//     registered by its author; a commit-reveal reservation wins over any
//     later registration of the same art by another author; an unclaimed
//     record of another author blocks for at most UnclaimedHoldBlocks
//     (engines.gno).
//   - I-15 TokenURI is only ever core's placeholder, an allowlisted SVG, a
//     header-checked raster data URI of an allowlisted type, or an ipfs://
//     CIDv1 URI (tokens.gno, engine.CheckMedia).
//   - I-17 an open collection (LaunchSpec.Mode "open") never has a
//     reserve, a commitment or a beacon and is never a fair launch.
//   - I-18 the payee deny set only grows (admin.gno, payee.deny).
//   - I-20 a token of a non-transferable (soulbound) collection never
//     changes owner: core refuses every transfer of it (the lockExt hook,
//     so also through a RealmTeller) and every approval through core, the
//     market never lists it, and the flag is fixed at creation; its owner
//     may burn it once the collection is Final. Every token's first owner
//     (the address it was minted to) is recorded once and never changes
//     (tokens.gno, FirstOwner).
//   - I-19 a collection is created on an engine only by the engine's
//     manifest author, by anyone while the policy is open, or by a holder
//     of a licence with room while it is licensed — judged at creation
//     only, so a later policy or licence change never touches an existing
//     collection; a licence's used count never exceeds its maximum; a
//     non-empty (engine, params) pair is refused to anyone but the current
//     creator of the first collection with it; no admin op changes a
//     policy or a licence (access.gno).
//
// core imports no mutable realm: minters and engines are known only by
// package path and interface value.
package core

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/royalty/v0"
	"gno.land/p/nt/grc721/v0"

	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/engine/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/safe/v2"
	"gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia4/types/v2"
)

// Hard limits. They are constants on purpose: nobody, admin included, can
// raise them after deploy (block counts assume ~3.54 s blocks, RA M-1).
const (
	ProtocolFeeCapBps  = 500           // 5% of any sale
	RoyaltyCapBps      = 1000          // 10% (RA M-3)
	CreateFeeCap       = 1_000_000_000 // 1,000 GNOT in ugnot
	MaxPayees          = 4
	MaxSupplyCap       = 10_000
	MaxMintPerTx       = 10               // hypothesis: measure n=10 gas/deposit on Onyx
	MaxReserveBps      = 1000             // creator reserve <= 10% of supply
	MaxSaleBlocks      = 732_000          // ~30 days
	RevealWindowMin    = 1_017            // ~1 hour
	RevealWindowMax    = 170_000          // ~7 days
	BeaconGraceBlocks  = 254              // beacon may reveal first in the window's last ~15 min (< RevealWindowMin, so the creator always gets to go first)
	TimelockBlocks     = 48_800           // ~48 hours
	MaxPauseBlocks     = 195_000          // ~8 days: pause budget per scope and window
	PauseWindowBlocks  = 732_000          // ~30 days (SA-L2)
	EngineFeeCapBps    = engine.MaxFeeBps // 5%: hard cap of an engine author's fee (platform cap <= this)
	ProviderWaitBlocks = 24_400           // ~24 h: Finalize waits this long after the deadline (or the round's binding) for a provider's round before falling back (CV-M1)
	ListingDepositCap  = 5_000_000        // 5 GNOT: hard cap of the market's listing deposit return (op listing.deposit, CV-L2)

	MaxNameLen        = 64
	MaxDescriptionLen = 1024
	MaxParamsLen      = 1024
	MinSecretLen      = 32
	MaxSecretLen      = 256
	MaxPageSize       = 50

	// Engine registry (ENG-M1, I-14).
	ReservationTTLBlocks = 170_000 // ~7 days: a fingerprint reservation is usable this long
	UnclaimedHoldBlocks  = 24_400  // ~1 day: an unclaimed record stops blocking the same art after this
	MinReserveSaltLen    = 32
	MaxReserveSaltLen    = 256

	// MaxDeniedPayees bounds the payee.deny entries (each payee check
	// looks the address up once; the bound only caps admin-made growth).
	MaxDeniedPayees = 64
)

// CoreVersion tells indexers and frontends which core they read (M-26).
const CoreVersion = "sinopia-core/4"

// Provenance badges (design §4.3).
const (
	BadgeBoth        = "2/2"
	BadgeCreatorOnly = "creator-only"
	BadgeBeaconOnly  = "beacon-only"
	BadgeFallback    = "fallback"
	BadgeOpen        = "open" // open mode: no secrets, never a fair launch (I-17)
)

type collection struct {
	id, name, symbol, description string
	creator, pendingCreator       address
	engineID, params              string
	traitTypes                    []string // the collection's trait list when it differs from the manifest's (nil = manifest)
	mode                          string   // types.ModeReveal or types.ModeOpen, set at Launch
	soulbound                     bool     // non-transferable, fixed at creation (I-20)
	maxSupply                     int64
	nextTID                       int64 // next token id; minted so far = nextTID-1
	reserved                      int64
	royaltyBps                    int64
	primaryPayees, royaltyPayees  []types.Payee
	minter                        string
	state                         types.State
	startHeight, endHeight        int64
	revealWindow                  int64
	closeHeight                   int64 // sell-out height, or endHeight once time ran out
	useBeacon                     bool
	beaconSource                  string // with useBeacon: types.BeaconCommitted or a randomness provider path
	createdHeight                 int64
	primaryBps                    int64    // protocol fee snapshot at Launch (SA-I5)
	engineBps                     int64    // engine-author fee snapshot at Launch (0 when creator == author)
	engineAuthor                  address  // who receives engineBps
	access                        string   // AccessAuthor, AccessLicence or AccessOpen: how the creator could use the engine (I-19)
	licenceFee                    int64    // engine fee of the licence it was created under, or LicenceFeeDefault (manifest fee)
	burnedCommits                 []string // commitments whose secret went public; never accepted again here (SA-L1)
	approvals                     avl.Tree // "o:"+owner+":"+operator -> int64 nonce (SA-L3; token nonces are packed in st)
	prov                          *provenance
	token                         *grc721.Token
	ledger                        *grc721.PrivateLedger
	roy                           *royalty.Royalty
	st                            *tokenState
	reservedTo                    avl.Tree // address -> int64 reserve tokens received (MintedBy = balance - this, I-9)
}

func (c *collection) minted() int64 { return c.nextTID - 1 }

var (
	// selfPath is this realm's package path, captured once in init so read
	// functions can derive sub-addresses without a cur.
	selfPath string

	collections avl.Tree // safe.PadInt(cid) -> *collection
	byCreator   avl.Tree // creator + ":" + padded cid -> cid
	collCount   int64
)

func init(cur realm) {
	selfPath = cur.PkgPath()
	initDeniedPayees()
}

// Version is CoreVersion (M-26).
func Version() string { return CoreVersion }

const cidWidth = 10

// collKey accepts a collection id as "<cid>" or as its token sub-path
// "c/<cid>" (the form a wallet derives from Token.ID(), "…/core#c/<cid>";
// K-1). Every function that takes a cid resolves it through
// mustCollection and then uses c.id only.
func collKey(cid string) string {
	if len(cid) > 2 && cid[0] == 'c' && cid[1] == '/' {
		cid = cid[2:]
	}
	return safe.PadInt(safe.ParseID("cid", cid), cidWidth)
}

func mustCollection(cid string) *collection {
	v := collections.Get(collKey(cid))
	if v == nil {
		panic("unknown collection " + strconv.Quote(cid))
	}
	return v.(*collection)
}

// stateAt is the effective state at height h; the stored state lags until
// the next write materializes it (refresh).
func stateAt(c *collection, h int64) types.State {
	switch c.state {
	case types.StateScheduled:
		if h > c.endHeight {
			return types.StateClosed
		}
		if h >= c.startHeight {
			return types.StateMinting
		}
	case types.StateMinting:
		if h > c.endHeight {
			return types.StateClosed
		}
	}
	return c.state
}

func refresh(c *collection, h int64) {
	s := stateAt(c, h)
	if s == c.state {
		return
	}
	if s == types.StateClosed && c.closeHeight == 0 {
		c.closeHeight = c.endHeight
	}
	c.state = s
	chain.Emit("CollectionState", "cid", c.id, "state", s.String())
}

// revealDeadline is when anyone may finalize without the missing secrets.
// It is at most endHeight + RevealWindowMax, which bounds the transfer
// lock (I-11).
func revealDeadline(c *collection) int64 {
	closed := c.closeHeight
	if closed == 0 {
		closed = c.endHeight
	}
	return closed + c.revealWindow
}

func caller(cur realm) address {
	return cur.Previous().Address()
}

// assertNoDeposit refuses coins on functions that take none, so nothing can
// get stuck in core (RA L-1). The origin-send envelope belongs to the first
// realm of the call; it is only ours to judge when a wallet called us.
func assertNoDeposit(cur realm) {
	if cur.Previous().IsUserCall() && !unsafe.OriginSend().IsZero() {
		panic("this function does not accept coins")
	}
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func height() int64 { return runtime.ChainHeight() }
