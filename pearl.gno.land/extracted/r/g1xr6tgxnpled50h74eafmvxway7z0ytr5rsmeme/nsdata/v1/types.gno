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
	"gno.land/p/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/grc721"
	"gno.land/p/nt/avl/v0"
)

// Timestamps are unix SECONDS, not time.Time, and that is the single
// biggest storage decision in this file. Measured on three throwaway
// realms (MAINNET.md §3d-i): two time.Time fields were 70% of a record,
// because each carries an unused nanosecond field and a *Location
// pointer for a value that is always UTC. Switching to int64 takes a
// real 7,385-byte domain record to 6,246 bytes on its own, and turns
// every lifecycle comparison into integer arithmetic.
//
// Nothing here stores a label. The AVL key already holds it — `label`
// for a domain, `domain*label` for a name — so a copy inside the record
// was paying storage forever to duplicate the thing used to find it.
type Domain struct {
	owner      address
	registered int64 // unix seconds
	expires    int64 // unix seconds
	frozen     bool

	// How long a resolver may cache an answer about this record, in
	// seconds, where 0 MEANS NEVER CACHE. Copied deliberately from the
	// ENS registry, which stores exactly this field with exactly this
	// rule, so integrators already know what to do with it.
	//
	// It exists because a name can be sold at any moment, and a cached
	// resolution then sends funds to the previous owner. A blanket
	// policy would be wrong for somebody receiving payments and
	// wastefully strict for somebody using a name as a handle, so the
	// person who knows the risk sets it. Typed rather than an `extra`
	// key because an avl entry costs an order of magnitude more than
	// eight bytes, and because integrators read it.
	ttl int64

	// Pricing, and anything a future logic realm needs. Not typed
	// fields, because pricing is policy and policy belongs in the
	// swappable half — the vault only has to remember the values.
	extra avl.Tree
}

type Name struct {
	owner      address
	registered int64
	expires    int64
	frozen     bool
	ttl        int64

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

// There is deliberately no `streak` field. It used to be stored and
// incremented on renewal, which breaks the moment multi-year
// registration exists: prepaying five years bumps it five times, so a
// name minted this morning would render "5 years held". A streak is
// meant to say how long somebody stuck around, and buying time is not
// the same as spending it. It is now derived from `registered` — see
// streakOf in auth.gno — which is always truthful, cannot be bought,
// resets naturally on reclaim, and removes a field instead of adding
// one.

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
	treasury address

	// Seconds, matching the record timestamps. These were time.Duration,
	// which meant every lifecycle comparison converted, and every read
	// through vm/qeval printed a nanosecond count that each caller had to
	// know to divide.
	termLength  int64 = 365 * 24 * 60 * 60
	gracePeriod int64 = 90 * 24 * 60 * 60

	labelPattern = `^[a-z0-9]+(-[a-z0-9]+)*$`
	minLabelLen  = 1
	maxLabelLen  = 63

	// Bounds on the extension slots. Storage written here is permanent
	// and paid for by the realm, so unbounded strings are griefing.
	maxExtraKeyLen   = 32
	maxExtraValueLen = 512
	maxExtraEntries  = 24

	// Upper bound on how many name records a single DeleteDomainRecord
	// call will destroy. Deletion is unbounded work over a domain that
	// may hold any number of names, and an unbounded loop in a realm
	// that cannot be redeployed is a domain that can never be deleted
	// at all once it grows past one block's gas. Settable, because the
	// right number depends on chain parameters nobody knows yet.
	maxDeletePerCall = 100

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
