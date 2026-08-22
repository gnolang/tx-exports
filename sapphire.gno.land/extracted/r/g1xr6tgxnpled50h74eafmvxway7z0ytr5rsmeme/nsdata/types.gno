// Package nsdata is the permanent vault — the one realm in the system
// that can never be replaced, because it holds every record. nslogic
// and nsview are swappable: deploy a new one, re-point, done. A "new
// nsdata" is an empty registry, so whatever ships here ships forever.
//
// Everything in this file is written under that constraint, which
// produces two rules the rest of the realm follows:
//
//  1. NOTHING IS A CONSTANT. Term length, grace period, size caps —
//     all of it is a variable with a setter. A `const` here is a
//     decision that can never be revisited, and there is no value in
//     this system worth that. (Grace period was the one that prompted
//     this; the reasoning applies to all of them equally.)
//
//  2. THE VAULT STORES, IT DOES NOT DECIDE. Business policy — pricing
//     math, validation, what a profile field means, how a page looks —
//     lives in the swappable realms. This realm keeps records, gates
//     writes, and stays out of the way. Anything it "knows" is a rule
//     that can never be changed.
//
// Rule 2 is why Domain and Name carry an `extra` tree instead of a
// growing list of typed fields. A struct field cannot be added after
// deployment, so every feature nobody thought of yet would be
// permanently unbuildable. Profile fields, per-domain pricing, tier
// markers, cross-chain addresses, key hashes — all of it lives in
// `extra`, written by whichever logic realm is current. New feature,
// new key: a logic swap, not a migration that cannot happen.
package nsdata

import (
	"time"

	"gno.land/p/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/grc721"
	"gno.land/p/nt/avl/v0"
)

type Domain struct {
	label      string
	owner      address
	registered time.Time
	expires    time.Time
	streak     int64
	frozen     bool

	// Pricing, and anything a future logic realm needs. Not typed
	// fields, because pricing is policy and policy belongs in the
	// swappable half — the vault only has to remember the values.
	extra avl.Tree
}

type Name struct {
	label      string
	domain     string
	owner      address
	registered time.Time
	expires    time.Time
	streak     int64
	frozen     bool

	// Whether a GRC-721 token was actually minted for this record.
	// Typed rather than an `extra` key because it gates real branching
	// (burn on reclaim, transferability) on hot paths, and getting it
	// wrong desynchronises the two ownership ledgers. The free tier
	// (SPEC.md §19) registers names with this false.
	isNFT bool

	// Profile fields, cross-chain addresses, management-key hashes,
	// tier markers — see the package comment.
	extra avl.Tree
}

var (
	nft *grc721.BasicNFT

	domains avl.Tree
	names   avl.Tree
	primary avl.Tree

	// Package-level extension slot, same reasoning as Domain/Name.extra:
	// somewhere to put global state nobody has thought of yet (points
	// balances, claim records, a custodian address) without needing a
	// new package var that cannot be added later.
	globals avl.Tree

	admin address // the vault door — see governance.gno for the full role model

	// The set of realms currently allowed to call mutations. A set, not a
	// single address, because the project will plausibly grow more than
	// one writer (a free-tier realm, a custodial relayer) and a single
	// slot would force them all into one realm.
	trustedLogicSet avl.Tree

	// -- config: every value below is settable, none is a const --
	treasury    address
	termLength  = 365 * 24 * time.Hour
	gracePeriod = 90 * 24 * time.Hour

	labelPattern = `^[a-z0-9]+(-[a-z0-9]+)*$`
	minLabelLen  = 1
	maxLabelLen  = 63

	// Bounds on the extension slots. Storage written here is permanent
	// and paid for by the realm, so unbounded strings are griefing.
	maxExtraKeyLen   = 32
	maxExtraValueLen = 512
	maxExtraEntries  = 24

	// Prefix for TokenURI. Points at whichever view realm currently
	// renders the artwork; settable so the art can be replaced without
	// touching this realm. See nft.gno.
	tokenURIBase = "/r/demo/nsview:token/"
)

func init(cur realm) {
	nft = grc721.NewBasicNFT(0, cur, "Meme Name Service", "MNS")
	deployer := cur.Previous().Address()
	admin = deployer
	recovery = deployer
	treasury = deployer
	// The trusted-logic set starts EMPTY and timelockDelay starts at
	// zero: deploy nsdata, deploy nslogic, then propose+execute the
	// grant. No mutation is callable until that happens.
	//
	// FIRST OPERATIONAL STEP AFTER DEPLOY, before anything of value
	// exists here: move `recovery` to a key held separately from
	// `admin` (ideally cold, ideally a multisig), then raise
	// timelockDelay. Until that is done both roles are the same key and
	// the whole recovery design is inert — it protects against one key
	// being lost or stolen, not against one key being both.
}
