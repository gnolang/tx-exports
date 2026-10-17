package nslogic

import (
	"chain"
	"strconv"
	"strings"
	"time"

	"gno.land/r/nym-mnsrehearsal001/nsdata/v2"
)

/*
REBUILDING THE REGISTRY ON A NEW CHAIN.

WHY THIS EXISTS. gno.land replaces testnets rather than preserving them:
topaz-1 was superseded by sapphire-1 on twenty-four hours' notice and
every name registered on it went to zero. tools/snapshot.js keeps a
complete off-chain copy of the vault for exactly that morning. This is
the other half — the path that turns a snapshot back into a live
registry, so that people who paid for a name get that name back rather
than an apology.

THIS IS A BACKDOOR, AND IT IS TREATED AS ONE.

A function that can mint any name, to any address, with any registration
date, is precisely the thing that would make every name here worthless
if it could be reached whenever the admin felt like it. Ownership means
nothing if history is editable on demand. So the capability is not
merely admin-gated — admin-gated is what everything else here already
is, and it is not enough for this. It is a ONE-SHOT:

  - it starts closed, and on a chain where nothing needs restoring it is
    sealed immediately and can never be used at all;
  - opening it is a deliberate, separate, announced act with a deadline
    attached, so forgetting to close it is not the same as leaving it
    open forever;
  - sealing is IRREVERSIBLE. Sealed cannot be reopened. There is no
    argument that unseals it, including a good one;
  - it refuses to touch a name that already exists. It fills gaps in an
    empty registry; it cannot rewrite a live one.

WHERE THE SEAL LIVES, AND WHY IT IS NOT HERE. This realm holds no state
at all — that is the whole reason prices and names survive a logic
upgrade untouched. If the seal lived in this realm's variables it would
reset to "never opened" the moment a new generation was deployed, which
would make "irreversible" a lie with a two-hour shelf life. It lives in
the vault's global slot instead, so a new logic generation inherits a
seal it cannot talk its way out of.

WHAT THAT DOES AND DOES NOT GUARANTEE. It is a real barrier against
every accident and against this realm being reached later for something
it was not built for. It is not a barrier against the admin themselves,
who can deploy a further logic realm and have the vault trust it — but
that is already total control by definition, and no flag in a realm the
admin can replace was ever going to change it. What the seal gives is
the thing that actually matters in practice: the state is public, it is
checkable by anybody at any time through RestoreStatus, and moving it
backwards leaves a permanent trace on chain.

WHAT IT DELIBERATELY DOES NOT RESTORE. Marketplace listings and open
votes. Those live in their own realms, are intentions rather than facts,
and are re-creatable by the people who made them in one transaction
each. Re-materialising somebody's month-old asking price as though they
had just set it would be inventing a decision on their behalf.
*/

// The vault key holding the state of this whole mechanism.
const keyRestore = "restore"

// Restore states, stored as a string in the vault's global slot.
const (
	restoreNever  = ""       // never opened; the normal state forever
	restoreSealed = "sealed" // closed permanently; cannot be reopened
	restoreOpen   = "open:"  // followed by the unix second it lapses
)

// The longest a restore window may be left open. A restore is a day of
// work, not a season, and an unbounded window is just "open forever"
// spelled differently — the failure here is nobody remembering to seal
// it, so the deadline seals it for them.
const maxRestoreDays = 30

// RestoreStatus reports the state of the restore mechanism in a form a
// person can read, and is deliberately PUBLIC AND UNAUTHENTICATED.
// Anybody at all can check whether this registry currently has a door in
// it, without asking us and without trusting the answer we would give.
//
// Returns the state ("never", "open", "expired" or "sealed"), the unix
// second an open window lapses (0 otherwise), and how many records have
// been restored in the lifetime of this vault.
func RestoreStatus() (state string, deadline int64, restored int64) {
	st, d := readRestoreState(nsdata.GetGlobal(keyRestore), time.Now().Unix())
	return st, d, restoredCount()
}

// readRestoreState is the state machine on its own, with the clock passed
// in. Split out so the one piece of logic that decides whether the door
// is open can be tested exhaustively without a chain under it.
func readRestoreState(raw string, now int64) (state string, deadline int64) {
	switch {
	case raw == restoreSealed:
		return "sealed", 0
	case strings.HasPrefix(raw, restoreOpen):
		d, err := strconv.ParseInt(raw[len(restoreOpen):], 10, 64)
		if err != nil || d <= 0 {
			// An unparseable deadline is read as NO permission. The safe
			// reading of a door whose lock is broken is "shut" — a corrupt
			// value must never widen what somebody is allowed to do.
			return "sealed", 0
		}
		if now >= d {
			return "expired", d
		}
		return "open", d
	}
	return "never", 0
}

const keyRestoredCount = "restored"

func restoredCount() int64 {
	if v := nsdata.GetGlobal(keyRestoredCount); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return 0
}

/*
THE RESTORE KEYS GO THROUGH THE VAULT'S RESERVED DOOR, and every refusal
panics.

They used to go through SetGlobalRecord, written for the first vault,
which had no reserved keys. This vault refuses "restore" and "restored"
there — and the three call sites threw the error away. So SealRestore
returned success and sealed nothing, OpenRestore returned success and
opened nothing (every Restore* call then said "never been opened", in the
middle of a paused migration), and the counter never moved. A returned
error in gno does not revert anything; ignoring one is how a control
reads as live while doing nothing.

SetReservedGlobalRecord is the machinery's own door, and the vault now
refuses to change a seal through it as well: a sealed restore stays
sealed whatever any logic realm asks, so a future logic generation
cannot talk its way out of it either.
*/
func setRestoreKey(cur realm, key, value string) {
	if err := nsdata.SetReservedGlobalRecord(cross(cur), key, value); err != nil {
		panic("nslogic: " + err.Error())
	}
}

func bumpRestored(cur realm, n int64) {
	setRestoreKey(cur, keyRestoredCount, strconv.FormatInt(restoredCount()+n, 10))
}

/*
assertNotRestoring CLOSES REGISTRATION WHILE A RESTORE WINDOW IS OPEN
(re-audit 2026-10-16, M-4). The window opens on an empty registry, and the
snapshots it replays are committed to the repository, so the list of who
held what is public: anybody could register a holder's name before its
batch arrived — at the genesis price, before the price rules were back —
and the holder never got it back, while the batch holding it reverted and
stopped the run. Every door that creates a name, or makes a free one
sellable, passes this: RegisterName and RegisterNameRef, RedeemCredit and
RegisterFor, GrantFreeName, UpgradeFreeName (and the lab's RegisterLabName).
Sealed, or lapsed, the registry sells again.
*/
func assertNotRestoring() {
	if st, _ := readRestoreState(nsdata.GetGlobal(keyRestore), time.Now().Unix()); st == "open" {
		panic("nslogic: the registry is being restored; registration reopens once the restore is sealed")
	}
}

// assertRestoring is the gate every Restore* function passes through.
func assertRestoring(cur realm) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	state, _, _ := RestoreStatus()
	switch state {
	case "open":
		return
	case "sealed":
		panic("nslogic: restore was sealed and cannot be reopened. This is " +
			"not recoverable by design — a registry whose history can be " +
			"rewritten on request does not have owners, it has guests.")
	case "expired":
		panic("nslogic: the restore window has lapsed. Deploy a fresh vault " +
			"and open a new window there; an expired one does not reopen.")
	}
	panic("nslogic: restore has never been opened. Call OpenRestore first, " +
		"and mean it.")
}

// OpenRestore opens the window, once, for a bounded number of days.
//
// Only ever valid on a chain where the registry is EMPTY because the
// previous chain was retired. It cannot be called on a vault that has
// been sealed, and it cannot be called twice.
func OpenRestore(cur realm, days int64) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "OpenRestore", "days", fmtInt(days))

	state, _, _ := RestoreStatus()
	if state != "never" {
		panic("nslogic: restore may be opened exactly once per vault; this " +
			"one is already " + state + ". A door that reopens is a door.")
	}
	if days < 1 || days > maxRestoreDays {
		panic("nslogic: a restore window must be between 1 and " +
			strconv.Itoa(maxRestoreDays) + " days")
	}
	/* THE PRECONDITION THE COMMENT ABOVE ALREADY CLAIMS.
	   "Only ever valid on a chain where the registry is EMPTY" was a
	   statement of intent that nothing enforced, so the window was
	   openable on a populated vault. The record restorers all refuse an
	   existing record, but RestoreNameField does not — it writes any
	   extension key on any EXISTING name, which includes the payment
	   addresses the site renders on a name's pay page. That is a way to
	   redirect somebody else's incoming money using only the admin key,
	   without the timelock and public event that granting a fresh logic
	   realm would cost. Now it is what it said it was. */
	/* NAMES ONLY, not domains. A registry is now born with its domains
	   (genesis), so "no domains" can never be true again and the guard
	   would have made disaster recovery impossible on every new chain.
	   The hazard it exists for is RestoreNameField writing onto EXISTING
	   NAMES — somebody's pay address — and only names carry that. */
	if _, n, _, _ := nsdata.Sizes(); n != 0 {
		panic("nslogic: restore is for a registry holding no names yet; " +
			"this one already holds records")
	}
	// TIMELOCKED (timelock.gno). This is the door that mints any name to
	// anybody with any date; on a fresh registry, before the first name and
	// before SealRestore, a stolen admin key could otherwise open it at once.
	requireAction(cur, actionID("OpenRestore", strconv.FormatInt(days, 10)))
	deadline := time.Now().Unix() + days*86400
	setRestoreKey(cur, keyRestore, restoreOpen+strconv.FormatInt(deadline, 10))
}

// SealRestore closes the door permanently. Valid from any state,
// including "never" — which is how it should be called on a chain that
// has nothing to restore, so that the capability is provably dead rather
// than merely unused.
//
// There is no matching unseal, and adding one later would defeat every
// word written at the top of this file.
func SealRestore(cur realm) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	emitAdmin(cur, "SealRestore")
	setRestoreKey(cur, keyRestore, restoreSealed)
	// Read back, not assumed: this call used to report success while the
	// state stayed "never".
	if st, _, _ := RestoreStatus(); st != "sealed" {
		panic("nslogic: the seal did not land; restore reads " + st)
	}
}

/*
RestoreDomain re-creates one domain with its original dates.

ORDER MATTERS: domains before their names. The vault refuses to register
a name under a domain that does not exist or had lapsed at the moment
the name claims to have been registered, which is correct behaviour and
also exactly the order a snapshot should be replayed in.

The vault's own registration path sets `registered` to whatever instant
it is handed and derives the expiry from the term length, so the
registration date is restored by passing the ORIGINAL one, and the
expiry is then corrected to the recorded value rather than a computed
one. Anything else would quietly hand everybody a fresh term.
*/
func RestoreDomain(cur realm, label string, owner address, registered, expires, ttl int64, frozen bool) {
	assertRestoring(cur)
	emitAdmin(cur, "RestoreDomain", "label", label, "owner", owner.String())
	if nsdata.DomainExists(label) {
		panic("nslogic: " + label + " already exists; restore fills an empty " +
			"registry and never overwrites a live record")
	}
	if registered <= 0 || expires <= 0 {
		panic("nslogic: a restored record needs its original dates")
	}
	if err := nsdata.RegisterDomainRecord(cross(cur), label, owner, registered); err != nil {
		panic("nslogic: " + err.Error())
	}
	nsdata.SetDomainExpiryRecord(cross(cur), label, expires)
	ttl = clampTTL(ttl)
	if ttl != 0 {
		if err := nsdata.SetDomainTTLRecord(cross(cur), label, ttl); err != nil {
			panic("nslogic: " + err.Error())
		}
	}
	if frozen {
		nsdata.SetDomainFrozen(cross(cur), label, true)
	}
	bumpRestored(cur, 1)
}

// RestoreName re-creates one name. See RestoreDomain on ordering and on
// why the dates are passed rather than computed.
//
// isNFT is carried across under its old name so snapshot blobs stay
// readable, and now means PAID: false restores a free-tier name with the
// hold on its token, so a restore can never quietly make a free name
// sellable.
func RestoreName(cur realm, label, domainLabel string, owner address, registered, expires, ttl int64, frozen, isNFT bool) {
	assertRestoring(cur)
	emitAdmin(cur, "RestoreName", "label", label, "domain", domainLabel, "owner", owner.String())
	if nsdata.NameExists(label, domainLabel) {
		panic("nslogic: " + label + "*" + domainLabel + " already exists; " +
			"restore fills an empty registry and never overwrites a live record")
	}
	if registered <= 0 || expires <= 0 {
		panic("nslogic: a restored record needs its original dates")
	}
	// RestoreNameRecord, not RegisterNameRecord: it ADOPTS a token the
	// ledger already holds, which is the whole point of a migration —
	// records move, tokens do not. If the ledger's holder is not the
	// snapshot's owner, the record is written for the holder and the
	// snapshot's profile is not replayed onto it.
	if err := nsdata.RestoreNameRecord(cross(cur), label, domainLabel, owner, registered, isNFT); err != nil {
		panic("nslogic: " + err.Error())
	}
	nsdata.SetNameExpiryRecord(cross(cur), label, domainLabel, expires)
	ttl = clampTTL(ttl)
	if ttl != 0 {
		if err := nsdata.SetNameTTLRecord(cross(cur), label, domainLabel, ttl); err != nil {
			panic("nslogic: " + err.Error())
		}
	}
	if frozen {
		nsdata.SetNameFrozen(cross(cur), label, domainLabel, true)
	}
	bumpRestored(cur, 1)
}

/*
RestoreNames replays many names in ONE transaction.

WHY A BLOB AND NOT A LOOP OF CALLS. A restore is done in one sitting
against a clock: the window is bounded and the people whose names are
missing are watching. One transaction per name is one signature per
name, and at a few hundred names that is an afternoon of clicking during
which a single mistimed refresh loses the thread. The compact form here
is unpleasant to read and it is the difference between a restore that
gets finished and one that gets abandoned half way.

The format is records separated by "|", fields separated by ",":

	label,domain,owner,registered,expires,ttl,frozen,isNFT

Neither a label nor a domain may contain "," or "|" — the character set
is enforced at registration — and an address contains neither, so the
split is unambiguous. tools/snapshot.js writes the JSON this is built
from; see tools/restore-blob.js for the conversion.

It stops at the first bad record and panics, taking the whole
transaction with it. That is deliberate: a partial batch that silently
skipped four names would leave four people without theirs and nothing
anywhere saying which four.
*/
func RestoreNames(cur realm, blob string) int {
	assertRestoring(cur)
	emitAdmin(cur, "RestoreNames", "bytes", fmtI(len(blob)))
	if blob == "" {
		panic("nslogic: nothing to restore")
	}
	recs := strings.Split(blob, "|")
	if len(recs) > 50 {
		panic("nslogic: at most 50 records per call, or the transaction " +
			"runs out of gas half way and it is unclear what landed")
	}
	done := 0
	for i, rec := range recs {
		if rec == "" {
			continue
		}
		r := parseRestoreRecord(rec, i)
		if nsdata.NameExists(r.label, r.domain) {
			panic("nslogic: record " + strconv.Itoa(i) + " (" + r.label + "*" + r.domain +
				") already exists; restore never overwrites a live record")
		}
		if err := nsdata.RestoreNameRecord(cross(cur), r.label, r.domain, r.owner, r.registered, r.isNFT); err != nil {
			panic("nslogic: record " + strconv.Itoa(i) + ": " + err.Error())
		}
		nsdata.SetNameExpiryRecord(cross(cur), r.label, r.domain, r.expires)
		if r.ttl != 0 {
			if err := nsdata.SetNameTTLRecord(cross(cur), r.label, r.domain, r.ttl); err != nil {
				panic("nslogic: record " + strconv.Itoa(i) + ": " + err.Error())
			}
		}
		if r.frozen {
			nsdata.SetNameFrozen(cross(cur), r.label, r.domain, true)
		}
		done++
	}
	bumpRestored(cur, int64(done))
	return done
}

// restoreRec is one parsed line of the blob.
type restoreRec struct {
	label, domain string
	owner         address
	registered    int64
	expires, ttl  int64
	frozen, isNFT bool
}

/*
parseRestoreRecord reads one record and refuses anything it is not sure
about.

EVERY CHECK HERE IS A PANIC AND NOT A SKIP. The blob is machine-written
from a snapshot, so a malformed record does not mean "this one name is
odd", it means the file is not what it was believed to be — and the
worst outcome available is a restore that appears to succeed while
quietly dropping the records it could not read. Somebody would find out
months later when one person asked where their name went.
*/
func parseRestoreRecord(rec string, i int) restoreRec {
	f := strings.Split(rec, ",")
	if len(f) != 8 {
		panic("nslogic: record " + strconv.Itoa(i) + " has " +
			strconv.Itoa(len(f)) + " fields, expected 8 " +
			"(label,domain,owner,registered,expires,ttl,frozen,isNFT)")
	}
	if f[0] == "" || f[1] == "" {
		panic("nslogic: record " + strconv.Itoa(i) + " has no name")
	}
	out := restoreRec{
		label:      f[0],
		domain:     f[1],
		owner:      address(f[2]),
		registered: mustSecs(f[3], i, "registered"),
		expires:    mustSecs(f[4], i, "expires"),
		ttl:        ttlSecs(f[5], i),
		frozen:     f[6] == "1",
		isNFT:      f[7] == "1",
	}
	if !out.owner.IsValid() {
		panic("nslogic: record " + strconv.Itoa(i) + " has an invalid owner address")
	}
	if out.registered <= 0 || out.expires <= 0 {
		panic("nslogic: record " + strconv.Itoa(i) + " is missing its original dates")
	}
	// An expiry before the registration is not a record, it is a
	// corruption, and restoring it would create a name that was already
	// reclaimable the day it was bought.
	if out.expires < out.registered {
		panic("nslogic: record " + strconv.Itoa(i) + " expires before it was registered")
	}
	return out
}

func mustSecs(s string, i int, what string) int64 {
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil || v < 0 {
		panic("nslogic: record " + strconv.Itoa(i) + " has a bad " + what)
	}
	return v
}

/*
ttlSecs reads a TTL and caps it at maxTTL (name.gno). A holder may have set
any non-negative int64 before the cap existed, and a snapshot written by
JavaScript rounded such a value above 2^53 — MaxInt64 came back as
9223372036854776000, which no int64 holds — so the whole batch of fifty
reverted (re-audit 2026-10-16, M-3). A run of digits too large to parse is
read as the longest a TTL may be; anything else malformed still refuses
the record.
*/
func ttlSecs(s string, i int) int64 {
	if v, err := strconv.ParseInt(s, 10, 64); err == nil && v >= 0 {
		return clampTTL(v)
	}
	if s != "" && len(s) <= 40 && strings.Trim(s, "0123456789") == "" {
		return maxTTL
	}
	panic("nslogic: record " + strconv.Itoa(i) + " has a bad ttl")
}

func clampTTL(v int64) int64 {
	if v > maxTTL {
		return maxTTL
	}
	return v
}

// RestoreNameField and RestoreDomainField put back a record's extension
// keys — profiles, cross-chain addresses, tier markers, and a domain's
// pricing rules. Separate calls because the extension slot has no fixed
// shape by design, which is the same reason the snapshot captures it by
// enumeration rather than by schema.
func RestoreNameField(cur realm, label, domainLabel, key, value string) {
	assertRestoring(cur)
	emitAdmin(cur, "RestoreNameField", "label", label, "domain", domainLabel, "key", key)
	/* ONLY ONTO A RECORD A RESTORE WROTE, AND ONLY FOR ITS HOLDER.

	   Profile fields include pay addresses, so replaying one is replaying
	   where money goes. Two audit findings meet here: a name sold between
	   the snapshot and the restore would have had the seller's addresses
	   written onto the buyer's name, and a name a user registered DURING
	   the restore window could have had its pay fields rewritten with the
	   admin key alone. RestoredFor is set only by RestoreNameRecord, and
	   only when the ledger's holder matched the snapshot.

	   Skipped rather than panicked, deliberately: a blob of fields rides in
	   one transaction, and one sold name must not abort everybody else's
	   restore. tools/restore-blob.js reads the fields back afterwards. */
	rf := nsdata.RestoredFor(label, domainLabel)
	if rf == "" || nsdata.GetNameOwner(label, domainLabel) != rf {
		return
	}
	if err := nsdata.SetNameExtraRecord(cross(cur), label, domainLabel, key, value); err != nil {
		panic("nslogic: " + err.Error())
	}
}

func RestoreDomainField(cur realm, label, key, value string) {
	assertRestoring(cur)
	emitAdmin(cur, "RestoreDomainField", "label", label, "key", key, "value", value)
	if err := nsdata.SetDomainExtraRecord(cross(cur), label, key, value); err != nil {
		panic("nslogic: " + err.Error())
	}
}

// RestoreGlobal puts back the vault's global slot — where the default
// price, the referral tiers and the seasonal card effects live.
//
// It refuses to write the restore keys themselves. Without that, a
// snapshot taken while a window was open would, on being replayed,
// cheerfully restore the open window along with everything else — and a
// seal that a backup file can undo is not a seal.
func RestoreGlobal(cur realm, key, value string) {
	assertRestoring(cur)
	emitAdmin(cur, "RestoreGlobal", "key", key, "value", value)
	if key == keyRestore || key == keyRestoredCount {
		panic("nslogic: the restore mechanism does not restore itself")
	}
	// NOR A ROLE, the rule genesis keeps (nsdata refusedInGenesis): the
	// granter, the keeper, the lab nomination or anything address-valued
	// is a power, set deliberately on the chain it belongs to, never by a
	// backup file round the timelock (re-audit 2026-10-16, L-7). SKIPPED,
	// not refused, like a stale reverse pointer: globals travel fifty to a
	// transaction, and one sandbox's lab nomination must not stop the whole
	// restore (review follow-up). The AdminAction above says it was asked.
	if key == keyGranter || key == keyKeeper || key == "labdomain" || looksLikeAddress(value) {
		chain.Emit("RestoreSkipped", "key", key, "why", "a role or an address; name it again through its own setter")
		return
	}
	if err := nsdata.SetGlobalRecord(cross(cur), key, value); err != nil {
		panic("nslogic: " + err.Error())
	}
}

// RestoreAccountField puts back one field of the per-address store —
// credits and their redemptions, referral counts. Without it a rebuilt
// registry would forget who had already spent their free name, and the
// migration grant could be claimed twice.
func RestoreAccountField(cur realm, owner address, key, value string) {
	assertRestoring(cur)
	emitAdmin(cur, "RestoreAccountField", "owner", owner.String(), "key", key, "value", value)
	// A credit's grant time is never in the future: one written through
	// this door would escape every void recovery could ever declare.
	if key == keyCredit && value != "" {
		if c := parseCredit(value); c.granted > 0 || c.used > 0 {
			if now := time.Now().Unix(); c.at > now {
				c.at = now
			}
			value = c.encode()
		}
	}
	if err := nsdata.SetAccountRecord(cross(cur), owner, key, value); err != nil {
		panic("nslogic: " + err.Error())
	}
}

// RestorePrimary puts back reverse resolution — which name an address
// answers to. Registration already sets this for an owner who had none,
// so this exists for the owners who had chosen a different one.
//
// SKIPPED, NOT REFUSED, when the vault would refuse it — the name is not
// there, or the ledger says somebody else holds it (a sale leaves the
// seller's pointer behind): pointers travel fifty to a transaction, and one
// stale pointer must not revert everybody else's (re-audit 2026-10-16, M-3).
func RestorePrimary(cur realm, owner address, label, domainLabel string) {
	assertRestoring(cur)
	emitAdmin(cur, "RestorePrimary", "owner", owner.String(), "label", label, "domain", domainLabel)
	if !nsdata.NameExists(label, domainLabel) || nsdata.GetNameOwner(label, domainLabel) != owner {
		return
	}
	if err := nsdata.SetPrimaryRecord(cross(cur), owner, label, domainLabel); err != nil {
		panic("nslogic: " + err.Error())
	}
}
