// Package core is the platform's immutable ledger (design §2.5.2): every
// collection, its official grc721 token and royalty, its provenance
// (commit–reveal v2), the engine registry, fees and the admin timelock.
//
// What core guarantees, whoever holds the admin key:
//
//   - I-1  admin cannot move, approve or burn a token, and holds no funds;
//     the op list is a closed set of parameters (admin.gno).
//   - I-2  pause only gates create, mint and trade. Transfer, burn,
//     finalize, distribute and every cancel stay open, and a pause expires
//     by itself after MaxPauseBlocks.
//   - I-5  supply only grows through the collection's bound minter, never
//     past maxSupply, and a token id is never minted twice.
//   - I-6  after Launch the engine, params, supply, payees, sale window and
//     commitments are frozen.
//   - I-10/11  a collection becomes Final at most once, only with both
//     reveals or after revealDeadline, and that deadline is bounded, so
//     the pre-reveal transfer lock always ends.
//   - I-12 engine code never runs on a state-changing path, except the
//     creator's own CreateCollection (ValidateParams) and the engine's own
//     RegisterEngine (one sample render). Every exported non-crossing
//     function is read-only, so an engine cannot call back into a mutator.
//   - I-13 every stored string passed safe.AssertText.
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

	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/safe/v1"
	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/types/v1"
)

// Hard limits. They are constants on purpose: nobody, admin included, can
// raise them after deploy (block counts assume ~3.54 s blocks, RA M-1).
const (
	ProtocolFeeCapBps = 500           // 5% of any sale
	RoyaltyCapBps     = 1000          // 10% (RA M-3)
	CreateFeeCap      = 1_000_000_000 // 1,000 GNOT in ugnot
	MaxPayees         = 4
	MaxSupplyCap      = 10_000
	MaxMintPerTx      = 10    // hypothesis: measure n=10 gas/deposit on Onyx
	MaxReserveBps     = 1000  // creator reserve <= 10% of supply
	MaxSaleBlocks     = 732_000 // ~30 days
	RevealWindowMin   = 1_017   // ~1 hour
	RevealWindowMax   = 170_000 // ~7 days
	BeaconGraceBlocks = 254     // beacon may reveal first in the window's last ~15 min (< RevealWindowMin, so the creator always gets to go first)
	TimelockBlocks    = 48_800  // ~48 hours
	MaxPauseBlocks    = 195_000 // ~8 days

	MaxNameLen        = 64
	MaxDescriptionLen = 1024
	MaxParamsLen      = 1024
	MinSecretLen      = 32
	MaxSecretLen      = 256
	MaxPageSize       = 50
)

// Provenance badges (design §4.3).
const (
	BadgeBoth        = "2/2"
	BadgeCreatorOnly = "creator-only"
	BadgeBeaconOnly  = "beacon-only"
	BadgeFallback    = "fallback"
)

type collection struct {
	id, name, symbol, description string
	creator, pendingCreator       address
	engineID, params              string
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
	createdHeight                 int64
	prov                          *provenance
	token                         *grc721.Token
	ledger                        *grc721.PrivateLedger
	roy                           *royalty.Royalty
	st                            *tokenState
	mintedBy                      avl.Tree // address -> int64, lifetime, written on every mint (I-9)
}

func (c *collection) minted() int64 { return c.nextTID - 1 }

var (
	// selfPath is this realm's package path, captured once in init so read
	// functions can derive sub-addresses without a cur.
	selfPath string

	collections avl.Tree // safe.PadInt(cid) -> *collection
	byCreator   avl.Tree // creator + ":" + padded cid -> cid
	collCount   int64
	usedCommits avl.Tree // commit hex -> cid; a commitment is single-use platform-wide (RA M-5)
)

func init(cur realm) {
	selfPath = cur.PkgPath()
}

const cidWidth = 10

func collKey(cid string) string {
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
