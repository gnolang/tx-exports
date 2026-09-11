// Package nsdata is the registry — the records behind every name.
//
// IT IS REPLACEABLE NOW, and that changes what every comment below means.
//
// Until this generation the vault held ownership as well as records, which
// made it the one realm that could never be redeployed: a "new nsdata"
// was an empty registry and everybody's names with it. So everything here
// was written as if it would ship forever — no constants, no policy, no
// display code — and the comments say "can never be replaced" throughout.
//
// Ownership has moved to nsnft, the small frozen token realm. This realm
// keeps records — dates, the frozen bit, TTL, profile data, reverse
// resolution, pricing globals, domains — and reads every owner from the
// ledger rather than storing one. Replacing it is a new package plus one
// Trust call on nsnft; no token moves, no holder notices. The integration
// address the outside world keeps is nsnft's, not this one's.
//
// The two old rules still hold, for a better reason than before:
//
//  1. NOTHING IS A CONSTANT. Term length, grace period, size caps — all
//     settable. Not because a mistake would be permanent any more, but
//     because a registry that needs a redeploy to change a number is a
//     registry that gets redeployed carelessly.
//
//  2. THE REGISTRY STORES, IT DOES NOT DECIDE. Pricing math, validation,
//     what a profile field means — all of it lives in nslogic. Anything
//     this realm "knows" is a rule that needs a migration to change.
//
// Rule 2 is why Domain and Name carry an `extra` tree instead of a
// growing list of typed fields.
package nsdata

import (
	"time"

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

/*
Name has NO OWNER FIELD, and that absence is the whole design.

The first attempt at moving ownership into a token realm kept a copy of
the owner here, and every bug it had followed from the copy: renewal
checked the copy and refused the real owner after a sale, snapshots
recorded the copy and would have handed sold names back to their sellers
on restore. There is one owner and it lives in nsnft. Every read asks it.

It also has no isNFT flag. Every name is a token; a free-tier name is a
token with a hold on it (lockBitFree). Four separate places used to read
"has no token" as "is free", and deleting the flag deletes that class of
bug rather than fixing four instances of it.
*/
type Name struct {
	registered int64
	expires    int64
	frozen     bool
	ttl        int64

	/* THE OWNERSHIP EPOCH this record's profile data belongs to.

	   nsnft moves a token's epoch on every mint and transfer. When the two
	   disagree, the extras and TTL here were written for a previous holder
	   — possibly through a sale on a marketplace this realm never hears
	   about — and they are treated as absent on read and destroyed before
	   the next write. See freshen in write.gno. */
	epoch int64

	/* WHO A RESTORE WROTE THIS RECORD FOR, or empty if no restore did.

	   nslogic.RestoreNameField replays profile data — pay addresses among
	   it — and may do so only onto a record a restore created, and only
	   while the ledger still says the snapshot's owner holds it. Without
	   this, a name sold between the snapshot and the restore had the
	   seller's pay addresses written onto the buyer's name, and any name a
	   user registered during the restore window could have its pay fields
	   rewritten with the admin key alone. */
	restoredFor address

	// Profile fields, cross-chain addresses, management-key hashes,
	// referrer — see the package comment. Only meaningful while `epoch`
	// matches the ledger.
	extra avl.Tree
}

/*
THE REGISTRY'S HOLD BITS on a token in nsnft. nsnft stores them and

	never interprets them; the vocabulary is this realm's.

	Separate bits so the two holds cannot undo each other: unfreezing a
	free-tier name must not make it sellable, and upgrading a frozen name
	must not unfreeze it.
*/
const (
	lockBitFree   = 0 // free tier, not yet paid for: not sellable
	lockBitFrozen = 1 // frozen by an admin: not movable while disputed
)

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
	deployer := cur.Previous().Address()
	admin = deployer
	recovery = deployer
	treasury = deployer

	// THE REGISTRY ARRIVES CONFIGURED. Domains, prices, referral tiers and
	// lifecycle settings are baked into genesis_data.gno and written here,
	// so a fresh chain is usable the moment this package lands — no trust
	// grant and no admin call needed, because this realm owns the state
	// it is writing. See genesis.gno.
	applyGenesis(deployer, time.Now().Unix())
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
